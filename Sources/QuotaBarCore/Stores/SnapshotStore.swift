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

/// Stale-while-revalidate snapshot store (OpenUsage behavior):
/// cached values show instantly, refresh runs on a timer, failures never wipe data.
/// Also enforces our rate-limit hygiene: manual-refresh throttle, 429 exponential backoff, 120 s timeout.
@MainActor
public final class SnapshotStore: ObservableObject {
    @Published public private(set) var states: [ProviderID: ProviderState] = [:]

    public static let manualThrottle: TimeInterval = 30
    public static let providerTimeout: TimeInterval = 120
    static let backoffSteps: [TimeInterval] = [5, 10, 20, 40, 60].map { $0 * 60 }

    private let runtimes: [ProviderRuntime]
    private let settings: SettingsStore
    private let cacheURL: URL
    private var timer: Timer?
    private var lastRefresh: Date?
    private var cancellables = Set<AnyCancellable>()

    public init(runtimes: [ProviderRuntime] = ProviderCatalog.all(), settings: SettingsStore, cacheURL: URL? = nil) {
        self.runtimes = runtimes
        self.settings = settings
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/snapshots.json")
        for r in runtimes { states[r.id] = ProviderState() }
        loadCache()

        settings.$refreshMinutes.removeDuplicates().sink { [weak self] m in self?.schedule(minutes: m) }.store(in: &cancellables)
    }

    public var enabledProviders: [ProviderID] {
        runtimes.map(\.id).filter(settings.isEnabled)
    }

    public var lastUpdated: Date? {
        states.values.compactMap(\.snapshot?.fetchedAt).max()
    }

    public var isRefreshing: Bool { states.values.contains(where: \.isRefreshing) }

    private func schedule(minutes: Int) {
        timer?.invalidate()
        let interval = TimeInterval(max(minutes, SettingsStore.minimumRefreshMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// - Parameter manual: user-initiated; throttled to once per 30 s (cached values are shown instead).
    public func refresh(manual: Bool = false) async {
        let now = Date()
        if manual, let last = lastRefresh, now.timeIntervalSince(last) < Self.manualThrottle { return }
        lastRefresh = now

        let due = runtimes.filter { r in
            guard settings.isEnabled(r.id), let s = states[r.id], !s.isRefreshing else { return false }
            return (s.backoffUntil ?? .distantPast) <= now
        }
        guard !due.isEmpty else { return }
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
