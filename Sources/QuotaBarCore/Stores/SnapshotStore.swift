import Combine
import Foundation

public struct ProviderState: Sendable {
    public var snapshot: ProviderSnapshot?
    public var error: String?
    public var isRefreshing = false
    var backoffUntil: Date?
    var backoffStep = 0

    public init() {}
    public var isStale: Bool { error != nil && snapshot != nil }
}

/// Stale-while-revalidate snapshot store:
/// cached values show instantly, refresh runs automatically on a `.common` RunLoop timer + wakeup check,
/// and failures never wipe data.
@MainActor
public final class SnapshotStore: ObservableObject {
    @Published public private(set) var states: [ProviderID: ProviderState] = [:]
    @Published public private(set) var carouselTick: Int = 0
    @Published public private(set) var isOnline = true

    public static let manualThrottle: TimeInterval = 15
    public static let providerTimeout: TimeInterval = 120
    static let backoffSteps: [TimeInterval] = [2, 5, 10, 20, 40].map { $0 * 60 }

    private let runtimes: [ProviderRuntime]
    private let settings: SettingsStore
    private let cacheURL: URL
    private let scanLocalMetadata: Bool
    private var refreshTimer: Timer?
    private var carouselTimer: Timer?
    private var lastRefresh: Date?
    private let network: NetworkMonitoring?
    private let networkRestoreDelay: TimeInterval
    private var pendingNetworkRefresh: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(runtimes: [ProviderRuntime] = ProviderCatalog.all(), settings: SettingsStore, cacheURL: URL? = nil,
                network: NetworkMonitoring? = nil, networkRestoreDelay: TimeInterval = 2) {
        self.runtimes = runtimes
        self.settings = settings
        self.network = network
        self.networkRestoreDelay = networkRestoreDelay
        self.scanLocalMetadata = (cacheURL == nil)
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/snapshots.json")
        for r in runtimes { states[r.id] = ProviderState() }
        loadCache()

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
        // Check every 30s whether any tracked provider's persisted `fetchedAt` has reached `refreshMinutes`.
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
        pendingNetworkRefresh?.cancel()
        guard online else { return }
        scheduleDelayedRefresh(after: networkRestoreDelay)
    }

    /// Called after the Mac wakes from sleep: the network is usually not ready yet, so wait before checking.
    public func systemDidWake(delay: TimeInterval = 4) {
        pendingNetworkRefresh?.cancel()
        scheduleDelayedRefresh(after: delay)
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

    /// Only refreshes providers whose persisted `fetchedAt` is older than the configured `refreshMinutes`
    /// (or has no snapshot yet), unless `manual: true` is explicitly requested by the user.
    public func refresh(manual: Bool = false) async {
        if !manual, !isOnline { return }
        let now = Date()
        let anyError = trackedProviders.contains { states[$0]?.error != nil }
        if manual, !anyError, let last = lastRefresh, now.timeIntervalSince(last) < Self.manualThrottle { return }

        let requiredAge = TimeInterval(max(settings.refreshMinutes, SettingsStore.minimumRefreshMinutes) * 60)
        let due = runtimes.filter { r in
            guard settings.isTracked(r.id), let s = states[r.id], !s.isRefreshing else { return false }
            if manual { return true }
            guard (s.backoffUntil ?? .distantPast) <= now else { return false }
            if let fetchedAt = s.snapshot?.fetchedAt {
                return now.timeIntervalSince(fetchedAt) >= requiredAge
            }
            return true // Never fetched before
        }
        guard !due.isEmpty else {
            if scanLocalMetadata {
                Task { await self.refreshLocalMetadata() }
            }
            return
        }
        lastRefresh = now
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
                localSpend: localSpend ?? s.snapshot?.localSpend
            )
            s.error = nil
            s.backoffStep = 0
            s.backoffUntil = nil
        case .failure(let error):
            s.error = error.localizedDescription // keep last good snapshot
            if var existing = s.snapshot, let localSpend {
                existing.localSpend = localSpend
                s.snapshot = existing
            }
            if case ProviderError.rateLimited(let retryAfter) = error {
                let step = Self.backoffSteps[min(s.backoffStep, Self.backoffSteps.count - 1)]
                s.backoffUntil = Date().addingTimeInterval(max(step, retryAfter ?? 0))
                s.backoffStep += 1
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
