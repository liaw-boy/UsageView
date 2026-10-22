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

    public static let manualThrottle: TimeInterval = 15
    public static let providerTimeout: TimeInterval = 120
    static let backoffSteps: [TimeInterval] = [2, 5, 10, 20, 40].map { $0 * 60 }

    private let runtimes: [ProviderRuntime]
    private let settings: SettingsStore
    private let cacheURL: URL
    private var refreshTimer: Timer?
    private var carouselTimer: Timer?
    private var lastRefresh: Date?
    private var cancellables = Set<AnyCancellable>()

    public init(runtimes: [ProviderRuntime] = ProviderCatalog.all(), settings: SettingsStore, cacheURL: URL? = nil) {
        self.runtimes = runtimes
        self.settings = settings
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/snapshots.json")
        for r in runtimes { states[r.id] = ProviderState() }
        loadCache()

        settings.$refreshMinutes
            .removeDuplicates()
            .sink { [weak self] m in self?.scheduleRefreshTimer(minutes: m) }
            .store(in: &cancellables)

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
        guard !due.isEmpty else { return }
        lastRefresh = now
        for r in due { states[r.id]?.isRefreshing = true }

        await withTaskGroup(of: (ProviderID, Result<[MetricLine], Error>).self) { group in
            for r in due {
                group.addTask { (r.id, await Self.runWithTimeout(r)) }
            }
            for await (id, result) in group { apply(id, result) }
        }
        saveCache()
    }

    private func apply(_ id: ProviderID, _ result: Result<[MetricLine], Error>) {
        var s = states[id] ?? ProviderState()
        s.isRefreshing = false
        switch result {
        case .success(let lines):
            s.snapshot = ProviderSnapshot(provider: id, lines: lines)
            s.error = nil
            s.backoffStep = 0
            s.backoffUntil = nil
        case .failure(let error):
            s.error = error.localizedDescription // keep last good snapshot
            if case ProviderError.rateLimited(let retryAfter) = error {
                let step = Self.backoffSteps[min(s.backoffStep, Self.backoffSteps.count - 1)]
                s.backoffUntil = Date().addingTimeInterval(max(step, retryAfter ?? 0))
                s.backoffStep += 1
            }
        }
        states[id] = s
    }

    nonisolated static func runWithTimeout(_ runtime: ProviderRuntime) async -> Result<[MetricLine], Error> {
        await withTaskGroup(of: Result<[MetricLine], Error>?.self) { group in
            group.addTask {
                do { return .success(try await runtime.fetch()) } catch { return .failure(error) }
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

    // Test hooks
    func backoffUntil(_ id: ProviderID) -> Date? { states[id]?.backoffUntil }
}
