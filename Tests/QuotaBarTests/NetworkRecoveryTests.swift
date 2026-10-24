import Foundation
import XCTest
@testable import QuotaBarCore

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
}

private struct CountingRuntime: ProviderRuntime {
    let id = ProviderID.claude
    let counter: CallCounter
    func fetch() async throws -> [MetricLine] {
        counter.increment()
        return [MetricLine(id: "5h", label: "5 小時", kind: .session, usedPercent: 10, resetsAt: nil)]
    }
}

final class NetworkRecoveryTests: XCTestCase {

    /// Writes a cache whose snapshot is `age` seconds old, so the store considers the provider due (or not).
    @MainActor
    private func makeStore(counter: CallCounter, snapshotAge: TimeInterval) -> SnapshotStore {
        let tmpCache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let cached = [ProviderSnapshot(
            provider: .claude,
            lines: [MetricLine(id: "5h", label: "5 小時", kind: .session, usedPercent: 10, resetsAt: nil)],
            fetchedAt: Date().addingTimeInterval(-snapshotAge)
        )]
        try? JSONEncoder().encode(cached).write(to: tmpCache)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpCache) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return SnapshotStore(
            runtimes: [CountingRuntime(counter: counter)],
            settings: settings,
            cacheURL: tmpCache,
            networkRestoreDelay: 0.05
        )
    }

    @MainActor
    func testOfflineAutomaticRefreshSkipsRequests() async {
        let counter = CallCounter()
        let store = makeStore(counter: counter, snapshotAge: 3600)
        store.networkChanged(online: false)

        await store.refresh(manual: false)

        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(store.isOnline)
        XCTAssertNil(store.states[.claude]?.error)
    }

    @MainActor
    func testManualRefreshStillAttemptsWhileOffline() async {
        let counter = CallCounter()
        let store = makeStore(counter: counter, snapshotAge: 3600)
        store.networkChanged(online: false)

        await store.refresh(manual: true)

        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    func testRestoringNetworkRefreshesStaleProviderOnce() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter, snapshotAge: 3600)
        store.networkChanged(online: false)

        // A burst of flapping events must coalesce into a single refresh.
        store.networkChanged(online: true)
        store.networkChanged(online: false)
        store.networkChanged(online: true)
        store.networkChanged(online: true)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(store.isOnline)
        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    func testRestoringNetworkDoesNotRefetchFreshProvider() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter, snapshotAge: 10)
        store.networkChanged(online: false)
        store.networkChanged(online: true)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(counter.count, 0)
    }

    @MainActor
    func testGoingOfflineCancelsPendingRestoreRefresh() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter, snapshotAge: 3600)
        store.networkChanged(online: false)
        store.networkChanged(online: true)
        store.networkChanged(online: false)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(counter.count, 0)
    }
}
