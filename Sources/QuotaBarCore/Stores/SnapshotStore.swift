import Combine
import Foundation

public struct ProviderState: Sendable {
    public var snapshot: ProviderSnapshot?
    public var error: String?
    public var isRefreshing = false
    /// Rate-limit (429) backoff: honoured by automatic and manual refreshes alike.
    var backoffUntil: Date?
    var backoffStep = 0
    var backoffServerRequested = false
    /// Short pause after any other failure so a flaky connection isn't hammered; manual refresh may override it.
    var retryAfter: Date?

    public init() {}
    public var isStale: Bool { error != nil && snapshot != nil }

    /// True while a 429 cooldown is active; refreshing sooner only prolongs the limit.
    public var isRateLimited: Bool { (backoffUntil ?? .distantPast) > Date() }

    /// The failure reason to show next to cached numbers, so a stale card never fails silently.
    /// Hidden while offline (the offline note covers it) and when there is no snapshot (the error is the card's main text).
    public func staleErrorMessage(isOffline: Bool) -> String? {
        guard snapshot != nil, !isOffline else { return nil }
        return error
    }
}

/// Stale-while-revalidate snapshot store:
/// cached values show instantly, refresh runs automatically on a `.common` RunLoop timer + wakeup check,
/// and failures never wipe data.
@MainActor
public final class SnapshotStore: ObservableObject {
    @Published public private(set) var states: [ProviderID: ProviderState] = [:]
    @Published public private(set) var carouselTick: Int = 0
    @Published public private(set) var isOnline = true
    /// One-line explanation shown briefly after a manual refresh that was held back by a cooldown.
    @Published public private(set) var refreshNotice: String?

    public static let manualThrottle: TimeInterval = 15
    public static let providerTimeout: TimeInterval = 120
    static let backoffSteps: [TimeInterval] = [2, 5, 10, 20, 40].map { $0 * 60 }
    static let failureBackoff: TimeInterval = 60
    /// While Claude's status line file is current, the API is only needed for what the file lacks (scoped model limits, extra usage).
    static let claudeAPIIntervalWithStatusLine: TimeInterval = 30 * 60

    static func rateLimitMessage(until: Date, serverRequested: Bool) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "請求太頻繁，" + (serverRequested ? "伺服器要求等到 " : "將於 ") + f.string(from: until) + " 後自動重試"
    }

    private let runtimes: [ProviderRuntime]
    private let settings: SettingsStore
    private let cacheURL: URL
    private let scanLocalMetadata: Bool
    private let claudeLimitsURL: URL?
    private var claudeLimitsWrittenAt: Date?
    private var claudeLimitsModified: Date?
    private var refreshTimer: Timer?
    private var carouselTimer: Timer?
    private var lastManualRefresh: Date?
    private var noticeTask: Task<Void, Never>?
    private let network: NetworkMonitoring?
    private let networkRestoreDelay: TimeInterval
    private var pendingNetworkRefresh: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(runtimes: [ProviderRuntime] = ProviderCatalog.all(), settings: SettingsStore, cacheURL: URL? = nil,
                network: NetworkMonitoring? = nil, networkRestoreDelay: TimeInterval = 2, claudeLimitsURL: URL? = nil) {
        self.runtimes = runtimes
        self.settings = settings
        self.network = network
        self.networkRestoreDelay = networkRestoreDelay
        self.scanLocalMetadata = (cacheURL == nil)
        self.claudeLimitsURL = claudeLimitsURL ?? (cacheURL == nil
            ? ClaudeStatusLineBridge().limitsURL
            : nil)
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/snapshots.json")
        for r in runtimes { states[r.id] = ProviderState() }
        loadCache()
        loadCooldowns()

        settings.$refreshMinutes
            .removeDuplicates()
            .sink { [weak self] m in self?.scheduleRefreshTimer(minutes: m) }
            .store(in: &cancellables)

        network?.start { [weak self] online in
            MainActor.assumeIsolated { self?.networkChanged(online: online) }
        }

        settings.$carouselSeconds
            .removeDuplicates()
            .sink { [weak self] s in self?.scheduleCarouselTimer(seconds: s) }
            .store(in: &cancellables)
    }

    public var trackedProviders: [ProviderID] {
        runtimes.map(\.id).filter(settings.isTracked)
    }

    public var panelProviders: [ProviderID] {
        runtimes.map(\.id).filter(settings.isShownInPanel)
    }

    public var menuBarProviders: [ProviderID] {
        runtimes.map(\.id).filter(settings.isShownInMenuBar)
    }

    public var lastUpdated: Date? {
        states.values.compactMap(\.snapshot?.fetchedAt).max()
    }

    public var isRefreshing: Bool { states.values.contains(where: \.isRefreshing) }

    private func scheduleRefreshTimer(minutes: Int) {
        refreshTimer?.invalidate()
        // Also re-reads Claude's status line file (mtime check only) on each tick. Check every 30s whether any tracked provider's persisted `fetchedAt` has reached `refreshMinutes`.
        // Because `fetchedAt` is saved on disk, restarting the app never resets or prematurely triggers API calls.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(manual: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    /// Tracks connectivity. Going offline pauses automatic fetches; coming back online re-checks for due providers
    /// after a short debounce (Wi-Fi often reports "satisfied" a moment before requests actually succeed).
    /// Never fetches more than `refresh()` already would: providers whose cache is still fresh are skipped.
    func networkChanged(online: Bool) {
        isOnline = online
        debugLog("network online=\(online)")
        pendingNetworkRefresh?.cancel()
        guard online else { return }
        clearFailurePauses()
        scheduleDelayedRefresh(after: networkRestoreDelay)
    }

    /// Called after the Mac wakes from sleep: the network is usually not ready yet, so wait before checking.
    public func systemDidWake(delay: TimeInterval = 4) {
        debugLog("system wake")
        pendingNetworkRefresh?.cancel()
        clearFailurePauses()
        scheduleDelayedRefresh(after: delay)
    }

    /// Failures before a reconnect or wake were most likely the network's fault, so the short pause is dropped.
    /// A 429 cooldown comes from the server and is never cleared here.
    private func clearFailurePauses() {
        for id in states.keys { states[id]?.retryAfter = nil }
    }

    private func scheduleDelayedRefresh(after delay: TimeInterval) {
        pendingNetworkRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh(manual: false)
        }
    }

    private func scheduleCarouselTimer(seconds: Int) {
        carouselTimer?.invalidate()
        let interval = TimeInterval(max(seconds, 2))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.carouselTick &+= 1
            }
        }
        RunLoop.main.add(t, forMode: .common)
        carouselTimer = t
    }

    /// The refresh rules, in one place:
    /// - Automatic: never while offline; a provider is due once its last success is older than
    ///   the user interval (Claude: 30 min while its status line file is current, since that file already supplies
    ///   5H/7D); skipped during a 429 cooldown or the short pause after any other failure.
    /// - Manual: overrides cache age and the short failure pause, never a 429 cooldown; at most one manual refresh
    ///   per `manualThrottle`.
    /// - Connectivity restored / wake: one automatic pass after clearing the short failure pause (429 cooldowns stay).
    func shouldFetch(_ id: ProviderID, state s: ProviderState, manual: Bool, now: Date) -> Bool {
        guard settings.isTracked(id), !s.isRefreshing else { return false }
        guard (s.backoffUntil ?? .distantPast) <= now else { return false }
        if manual {
            return true
        }
        guard (s.retryAfter ?? .distantPast) <= now else { return false }
        guard let lastAPI = s.snapshot?.lastAPIFetch else { return true } // Never fetched before
        var requiredAge = TimeInterval(settings.refreshMinutes * 60)
        if id == .claude, let written = claudeLimitsWrittenAt, now.timeIntervalSince(written) < requiredAge {
            requiredAge = max(requiredAge, Self.claudeAPIIntervalWithStatusLine)
        }
        return now.timeIntervalSince(lastAPI) >= requiredAge
    }

    /// Refreshes the providers that are due under the rules in `shouldFetch`.
    public func refresh(manual: Bool = false) async {
        applyClaudeStatusLineLimits()
        if !manual, !isOnline { return }
        let now = Date()
        if manual {
            if let last = lastManualRefresh, now.timeIntervalSince(last) < Self.manualThrottle { return }
            lastManualRefresh = now
        }

        let due = runtimes.filter { r in
            guard let s = states[r.id] else { return false }
            return shouldFetch(r.id, state: s, manual: manual, now: now)
        }
        debugLog("refresh manual=\(manual) online=\(isOnline) due=\(due.map { $0.id.rawValue })")
        if manual { announceCooldowns(now: now) }
        guard !due.isEmpty else {
            if scanLocalMetadata {
                Task { await self.refreshLocalMetadata() }
            }
            return
        }
        for r in due { states[r.id]?.isRefreshing = true }

        await withTaskGroup(of: (ProviderID, Result<ProviderFetchResult, Error>).self) { group in
            for r in due {
                group.addTask { (r.id, await Self.runWithTimeout(r)) }
            }
            for await (id, result) in group { apply(id, result, localSpend: nil) }
        }
        saveCache()
        if scanLocalMetadata {
            Task { await self.refreshLocalMetadata() }
        }
    }

    /// Uses the limits Claude Code's status line last saw when they are newer than our snapshot, so the card stays
    /// current without calling the rate-limited usage endpoint. Windows the file lacks (e.g. scoped model limits) keep
    /// their last API values; a 429 cooldown stays in place but no longer shows as an error.
    func applyClaudeStatusLineLimits() {
        guard settings.isTracked(.claude), let url = claudeLimitsURL,
              let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              modified != claudeLimitsModified else { return }
        claudeLimitsModified = modified
        guard let body = Parse.object(try? Data(contentsOf: url)),
              let (writtenAt, fresh) = ClaudeMapper.statusLineLimits(body),
              writtenAt <= Date().addingTimeInterval(60)
        else { return }
        claudeLimitsWrittenAt = writtenAt
        guard writtenAt > (states[.claude]?.snapshot?.fetchedAt ?? .distantPast) else { return }
        var s = states[.claude] ?? ProviderState()
        let old = s.snapshot
        var lines = old?.lines.map { line in fresh.first { $0.id == line.id } ?? line } ?? []
        lines += fresh.filter { f in !lines.contains { $0.id == f.id } }
        s.snapshot = ProviderSnapshot(provider: .claude, lines: lines, fetchedAt: writtenAt, planName: old?.planName,
                                      extraUsageText: old?.extraUsageText, localSpend: old?.localSpend,
                                      windowSpend: old?.windowSpend)
        s.snapshot?.apiFetchedAt = old?.lastAPIFetch ?? .distantPast // never read the API yet: due right away
        s.error = nil
        states[.claude] = s
        saveCache()
    }

    /// Re-runs one provider immediately, bypassing the refresh interval. Only meant for local-only providers
    /// (OpenCode reads its own database), e.g. after the user changes its quota settings.
    public func refreshNow(_ id: ProviderID) async {
        guard let runtime = runtimes.first(where: { $0.id == id }), settings.isTracked(id),
              states[id]?.isRefreshing != true else { return }
        states[id]?.isRefreshing = true
        let result = await Self.runWithTimeout(runtime)
        apply(id, result, localSpend: nil)
        saveCache()
        if scanLocalMetadata { await refreshLocalMetadata() }
    }

    /// Updates offline local token spend and locally readable plan names on cached snapshots without hitting remote APIs.
    public func refreshLocalMetadata() async {
        var changed = false
        for id in trackedProviders {
            guard var snap = states[id]?.snapshot else { continue }
            let spend = await LocalUsageScanner.shared.scan(provider: id)
            if snap.localSpend != spend {
                snap.localSpend = spend
                changed = true
            }
            if id == .claude, snap.planName == nil,
               let plan = ClaudeAuthStore(credentials: SystemCredentialSource()).credentialsInfo()?.planName {
                snap.planName = plan
                changed = true
            }
            if id == .antigravity, snap.planName == nil, snap.lines.contains(where: { $0.id == "argon-weekly" }) {
                snap.planName = "Pro"
                changed = true
            }
            if changed {
                states[id]?.snapshot = snap
            }
        }
        if changed { saveCache() }
    }

    private func apply(_ id: ProviderID, _ result: Result<ProviderFetchResult, Error>, localSpend: LocalSpendSummary?) {
        var s = states[id] ?? ProviderState()
        s.isRefreshing = false
        switch result {
        case .success(let fetched):
            s.snapshot = ProviderSnapshot(
                provider: id,
                lines: fetched.lines,
                planName: fetched.planName ?? s.snapshot?.planName,
                extraUsageText: fetched.extraUsageText,
                localSpend: localSpend ?? s.snapshot?.localSpend,
                windowSpend: fetched.windowSpend
            )
            s.error = nil
            s.backoffStep = 0
            s.backoffUntil = nil
            s.retryAfter = nil
        case .failure(let error):
            s.error = error.localizedDescription // keep last good snapshot
            if var existing = s.snapshot, let localSpend {
                existing.localSpend = localSpend
                s.snapshot = existing
            }
            if case ProviderError.rateLimited(let retryAfter) = error {
                let step = Self.backoffSteps[min(s.backoffStep, Self.backoffSteps.count - 1)]
                let until = Date().addingTimeInterval(max(step, retryAfter ?? 0))
                s.backoffUntil = until
                s.backoffStep += 1
                s.retryAfter = nil
                s.backoffServerRequested = (retryAfter ?? 0) > step
                s.error = Self.rateLimitMessage(until: until, serverRequested: s.backoffServerRequested)
            } else {
                s.retryAfter = Date().addingTimeInterval(Self.failureBackoff)
            }
        }
        states[id] = s
    }

    nonisolated static func runWithTimeout(_ runtime: ProviderRuntime) async -> Result<ProviderFetchResult, Error> {
        await withTaskGroup(of: Result<ProviderFetchResult, Error>?.self) { group in
            group.addTask {
                do { return .success(try await runtime.fetchResult()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(providerTimeout))
                return Task.isCancelled ? nil : .failure(ProviderError.timeout)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(ProviderError.timeout)
        }
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let snaps = try? JSONDecoder().decode([ProviderSnapshot].self, from: data) else { return }
        for s in snaps where states[s.provider] != nil { states[s.provider]?.snapshot = s }
    }

    private func saveCache() {
        let snaps = states.values.compactMap(\.snapshot)
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snaps).write(to: cacheURL, options: .atomic)
        saveCooldowns()
    }

    // MARK: - Cooldowns

    /// A 429 cooldown outlives the process: restarting the app must not fire a request the server told us to hold back.
    private struct SavedCooldown: Codable {
        var until: Date
        var step: Int
        var serverRequested: Bool
    }

    private var cooldownURL: URL {
        cacheURL.deletingPathExtension().appendingPathExtension("cooldowns.json")
    }

    private func saveCooldowns() {
        var saved: [String: SavedCooldown] = [:]
        for (id, s) in states {
            guard let until = s.backoffUntil else { continue }
            saved[id.rawValue] = SavedCooldown(until: until, step: s.backoffStep, serverRequested: s.backoffServerRequested)
        }
        try? JSONEncoder().encode(saved).write(to: cooldownURL, options: .atomic)
    }

    private func loadCooldowns() {
        guard let data = try? Data(contentsOf: cooldownURL),
              let saved = try? JSONDecoder().decode([String: SavedCooldown].self, from: data) else { return }
        let now = Date()
        for (raw, c) in saved {
            guard let id = ProviderID(rawValue: raw), states[id] != nil, c.until > now else { continue }
            states[id]?.backoffUntil = c.until
            states[id]?.backoffStep = c.step
            states[id]?.backoffServerRequested = c.serverRequested
            states[id]?.error = Self.rateLimitMessage(until: c.until, serverRequested: c.serverRequested)
        }
    }

    /// A manual refresh skips providers in a cooldown; say so instead of silently doing nothing.
    private func announceCooldowns(now: Date) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let held = runtimes.compactMap { r -> String? in
            guard settings.isTracked(r.id), let until = states[r.id]?.backoffUntil, until > now else { return nil }
            return "\(r.id.displayName) 冷卻中，\(f.string(from: until)) 後才能重試"
        }
        guard !held.isEmpty else { return }
        refreshNotice = held.joined(separator: "；")
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.refreshNotice = nil }
        }
    }

    // Test & Docs preview hooks
    func backoffUntil(_ id: ProviderID) -> Date? { states[id]?.backoffUntil }

    public func populateShowcaseData() {
        let now = Date()
        states[.claude]?.snapshot = ProviderSnapshot(
            provider: .claude,
            lines: [
                MetricLine(id: "5h", label: "5H", kind: .session, usedPercent: 28, resetsAt: now.addingTimeInterval(3 * 3600 + 18 * 60)),
                MetricLine(id: "7d", label: "7D", kind: .weekly, usedPercent: 14, resetsAt: now.addingTimeInterval(5 * 86400 + 12 * 3600)),
            ],
            fetchedAt: now,
            planName: "Max 5x",
            localSpend: LocalSpendSummary(todayCostUSD: 18.40, todayTokens: 2_450_000, monthCostUSD: 342.80, monthTokens: 48_900_000)
        )
        states[.codex]?.snapshot = ProviderSnapshot(
            provider: .codex,
            lines: [
                MetricLine(id: "5h", label: "5H", kind: .session, usedPercent: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
                MetricLine(id: "7d", label: "7D", kind: .weekly, usedPercent: 45, resetsAt: now.addingTimeInterval(4 * 86400 + 6 * 3600)),
            ],
            fetchedAt: now,
            planName: "Plus",
            extraUsageText: "點數餘額 $12.80 · 320 點",
            localSpend: LocalSpendSummary(todayCostUSD: 6.20, todayTokens: 1_120_000, monthCostUSD: 118.50, monthTokens: 21_400_000)
        )
        states[.opencode]?.snapshot = ProviderSnapshot(
            provider: .opencode,
            lines: [],
            fetchedAt: now,
            planName: "本機花費",
            localSpend: LocalSpendSummary(todayCostUSD: 5.11, todayTokens: 1_200_000, weekCostUSD: 12.40, weekTokens: 3_100_000, monthCostUSD: 38.20, monthTokens: 9_800_000)
        )
        states[.antigravity]?.snapshot = ProviderSnapshot(
            provider: .antigravity,
            lines: [
                MetricLine(id: "gemini-5h", label: "Gemini · 5H", kind: .session, pool: "gemini", usedPercent: 18, resetsAt: now.addingTimeInterval(42 * 60)),
                MetricLine(id: "gemini-weekly", label: "Gemini · 7D", kind: .weekly, pool: "gemini", usedPercent: 14, resetsAt: now.addingTimeInterval(6 * 86400 + 4 * 3600)),
                MetricLine(id: "3p-5h", label: "Claude/GPT · 5H", kind: .session, pool: "3p", usedPercent: 32, resetsAt: now.addingTimeInterval(2 * 3600 + 15 * 60)),
                MetricLine(id: "3p-weekly", label: "Claude/GPT · 7D", kind: .weekly, pool: "3p", usedPercent: 47, resetsAt: now.addingTimeInterval(6 * 86400 + 4 * 3600)),
                MetricLine(id: "argon-weekly", label: "Argon · 7D", kind: .weekly, pool: "argon", usedPercent: 77, resetsAt: now.addingTimeInterval(6 * 86400 + 19 * 3600)),
            ],
            fetchedAt: now,
            planName: "Pro",
            localSpend: LocalSpendSummary(todayCostUSD: 24.60, todayTokens: 4_850_000, monthCostUSD: 412.90, monthTokens: 82_300_000)
        )
    }
}
