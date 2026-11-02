import Foundation
import XCTest
@testable import QuotaBarCore

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func bump() { lock.lock(); _count += 1; lock.unlock() }
}

private struct FailingRuntime: ProviderRuntime {
    let id = ProviderID.claude
    let attempts: Attempts
    let error: ProviderError
    func fetch() async throws -> [MetricLine] {
        attempts.bump()
        throw error
    }
}

final class RetryBackoffTests: XCTestCase {
    @MainActor
    private func makeStore(_ attempts: Attempts, error: ProviderError, restoreDelay: TimeInterval = 2) -> SnapshotStore {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return SnapshotStore(
            runtimes: [FailingRuntime(attempts: attempts, error: error)],
            settings: settings,
            cacheURL: cache,
            networkRestoreDelay: restoreDelay
        )
    }

    @MainActor
    func testManualRefreshIsThrottledEvenWhenAProviderHasAnError() async {
        let attempts = Attempts()
        let store = makeStore(attempts, error: .timeout)

        await store.refresh(manual: true)
        await store.refresh(manual: true)
        await store.refresh(manual: true)

        XCTAssertEqual(attempts.count, 1)
    }

    @MainActor
    func testReconnectClearsTheShortFailurePause() async throws {
        let attempts = Attempts()
        let store = makeStore(attempts, error: .timeout, restoreDelay: 0.05)

        await store.refresh(manual: false)
        await store.refresh(manual: false)
        XCTAssertEqual(attempts.count, 1)

        store.networkChanged(online: false)
        store.networkChanged(online: true)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(attempts.count, 2)
    }

    @MainActor
    func testReconnectDoesNotClearARateLimitCooldown() async throws {
        let attempts = Attempts()
        let store = makeStore(attempts, error: .rateLimited(retryAfter: 600), restoreDelay: 0.05)

        await store.refresh(manual: false)
        store.networkChanged(online: false)
        store.networkChanged(online: true)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(attempts.count, 1)
    }

    @MainActor
    func testAutomaticRetriesPauseAfterAnyFailure() async {
        let attempts = Attempts()
        let store = makeStore(attempts, error: .timeout)

        await store.refresh(manual: false)
        await store.refresh(manual: false)
        await store.refresh(manual: false)

        XCTAssertEqual(attempts.count, 1)
    }

    @MainActor
    func testManualRefreshOverridesShortFailureBackoff() async {
        let attempts = Attempts()
        let store = makeStore(attempts, error: .timeout)

        await store.refresh(manual: false)
        await store.refresh(manual: true)

        XCTAssertEqual(attempts.count, 2)
    }

    @MainActor
    func testManualRefreshRespectsRateLimitBackoff() async {
        let attempts = Attempts()
        let store = makeStore(attempts, error: .rateLimited(retryAfter: 600))

        await store.refresh(manual: true)
        await store.refresh(manual: true)
        await store.refresh(manual: true)

        XCTAssertEqual(attempts.count, 1)
        XCTAssertNotNil(store.backoffUntil(.claude))
    }

    @MainActor
    private func storeSharing(cache: URL, _ attempts: Attempts, error: ProviderError) -> SnapshotStore {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return SnapshotStore(runtimes: [FailingRuntime(attempts: attempts, error: error)], settings: settings, cacheURL: cache)
    }

    private func tempCache() -> URL {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: cache.deletingPathExtension().appendingPathExtension("cooldowns.json"))
        }
        return cache
    }

    @MainActor
    func testRateLimitCooldownSurvivesARestart() async {
        let cache = tempCache()
        let first = Attempts()
        await storeSharing(cache: cache, first, error: .rateLimited(retryAfter: 600)).refresh(manual: false)
        XCTAssertEqual(first.count, 1)

        let second = Attempts()
        let restarted = storeSharing(cache: cache, second, error: .rateLimited(retryAfter: 600))
        await restarted.refresh(manual: false)
        await restarted.refresh(manual: true)

        XCTAssertEqual(second.count, 0)
        XCTAssertTrue(restarted.states[.claude]?.error?.hasPrefix("請求太頻繁，伺服器要求等到 ") == true)
    }

    @MainActor
    func testExpiredCooldownIsNotRestored() async throws {
        let cache = tempCache()
        let expired = ["claude": ["until": Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate, "step": 2, "serverRequested": false] as [String: Any]]
        try JSONSerialization.data(withJSONObject: expired)
            .write(to: cache.deletingPathExtension().appendingPathExtension("cooldowns.json"))

        let attempts = Attempts()
        await storeSharing(cache: cache, attempts, error: .timeout).refresh(manual: false)

        XCTAssertEqual(attempts.count, 1)
    }

    @MainActor
    func testManualRefreshDuringCooldownExplainsWhy() async {
        let attempts = Attempts()
        let store = makeStore(attempts, error: .rateLimited(retryAfter: 600))
        XCTAssertNil(store.refreshNotice)

        await store.refresh(manual: false)
        await store.refresh(manual: true)

        XCTAssertEqual(attempts.count, 1)
        let notice = store.refreshNotice ?? ""
        XCTAssertNotNil(notice.range(of: #"冷卻中，\d{2}:\d{2} 後才能重試"#, options: .regularExpression), notice)
    }

    @MainActor
    func testRateLimitMessageNamesTheRetryTime() async {
        let store = makeStore(Attempts(), error: .rateLimited(retryAfter: nil))

        await store.refresh(manual: true)

        let message = store.states[.claude]?.error ?? ""
        XCTAssertNotNil(message.range(of: #"^請求太頻繁，將於 \d{2}:\d{2} 後自動重試$"#, options: .regularExpression), message)
    }

    @MainActor
    func testServerRequestedWaitIsReportedAsSuch() async {
        let store = makeStore(Attempts(), error: .rateLimited(retryAfter: 7200))

        await store.refresh(manual: true)

        XCTAssertTrue(store.states[.claude]?.error?.hasPrefix("請求太頻繁，伺服器要求等到 ") == true)
    }
}

private struct OkRuntime: ProviderRuntime {
    let id: ProviderID
    let attempts: Attempts
    func fetch() async throws -> [MetricLine] {
        attempts.bump()
        return [MetricLine(id: "5h", label: "5 小時", kind: .session, usedPercent: 10, resetsAt: nil)]
    }
}

final class RefreshIntervalTests: XCTestCase {
    @MainActor
    private func attempts(for id: ProviderID, snapshotAgeMinutes: Double, manual: Bool = false) async -> Int {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        let cached = [ProviderSnapshot(
            provider: id,
            lines: [MetricLine(id: "5h", label: "5 小時", kind: .session, usedPercent: 10, resetsAt: nil)],
            fetchedAt: Date().addingTimeInterval(-snapshotAgeMinutes * 60)
        )]
        try? JSONEncoder().encode(cached).write(to: cache)
        let counter = Attempts()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.refreshMinutes = 5
        let store = SnapshotStore(runtimes: [OkRuntime(id: id, attempts: counter)], settings: settings, cacheURL: cache)
        await store.refresh(manual: manual)
        return counter.count
    }

    @MainActor
    func testClaudeFollowsTheConfiguredInterval() async {
        let tooSoon = await attempts(for: .claude, snapshotAgeMinutes: 3)
        let due = await attempts(for: .claude, snapshotAgeMinutes: 6)
        XCTAssertEqual(tooSoon, 0)
        XCTAssertEqual(due, 1)
    }

    @MainActor
    func testManualRefreshIsNotGatedByCacheAge() async {
        let claude = await attempts(for: .claude, snapshotAgeMinutes: 0.5, manual: true)
        let codex = await attempts(for: .codex, snapshotAgeMinutes: 0.5, manual: true)
        XCTAssertEqual(claude, 1)
        XCTAssertEqual(codex, 1)
    }
}

final class ClaudeStatusLineLimitsTests: XCTestCase {
    func testMapperReadsStatusLineFile() throws {
        let body: [String: Any] = [
            "written_at": 1_800_000_000,
            "rate_limits": [
                "five_hour": ["used_percentage": 23.5, "resets_at": 1_800_010_000],
                "seven_day": ["used_percentage": 140, "resets_at": 1_800_500_000],
            ],
        ]
        let (writtenAt, lines) = try XCTUnwrap(ClaudeMapper.statusLineLimits(body))
        XCTAssertEqual(writtenAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(lines.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(lines[0].usedPercent, 23.5)
        XCTAssertEqual(lines[0].resetsAt, Date(timeIntervalSince1970: 1_800_010_000))
        XCTAssertEqual(lines[1].usedPercent, 100) // clamped
        XCTAssertNil(ClaudeMapper.statusLineLimits(["written_at": 1, "rate_limits": [String: Any]()]))
        XCTAssertNil(ClaudeMapper.statusLineLimits(["rate_limits": body["rate_limits"]!]))
        // Forged values must not reach Int conversions: NaN is dropped, an absurd reset time is ignored.
        let forged = ClaudeMapper.statusLineLimits(["written_at": 1_800_000_000, "rate_limits": [
            "five_hour": ["used_percentage": "nan"],
            "seven_day": ["used_percentage": 3, "resets_at": "1e300"],
        ]])
        XCTAssertEqual(forged?.lines.map(\.id), ["seven_day"])
        XCTAssertNil(forged?.lines.first?.resetsAt)
        XCTAssertNil(ClaudeMapper.statusLineLimits(["written_at": "1e300", "rate_limits": body["rate_limits"]!]))
    }

    @MainActor
    func testNewerFileUpdatesClaudeWithoutCallingTheAPI() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("snapshots.json")
        let limits = dir.appendingPathComponent("limits.json")
        let old = Date().addingTimeInterval(-20 * 60)
        try JSONEncoder().encode([ProviderSnapshot(provider: .claude, lines: [
            MetricLine(id: "five_hour", label: "5H", kind: .session, usedPercent: 90, resetsAt: nil),
            MetricLine(id: "weekly_fable", label: "Fable · 7D", kind: .weekly, usedPercent: 5, resetsAt: nil),
        ], fetchedAt: old)]).write(to: cache)
        let written = Date().addingTimeInterval(-30).timeIntervalSince1970
        try JSONSerialization.data(withJSONObject: [
            "written_at": written,
            "rate_limits": ["five_hour": ["used_percentage": 12, "resets_at": written + 3600]],
        ]).write(to: limits)

        let counter = Attempts()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.refreshMinutes = 5
        let store = SnapshotStore(runtimes: [OkRuntime(id: .claude, attempts: counter)], settings: settings,
                                  cacheURL: cache, claudeLimitsURL: limits)
        await store.refresh(manual: false)

        XCTAssertEqual(counter.count, 0)
        let snap = try XCTUnwrap(store.states[.claude]?.snapshot)
        XCTAssertEqual(snap.lines.map(\.id), ["five_hour", "weekly_fable"])
        XCTAssertEqual(snap.lines[0].usedPercent, 12)
        XCTAssertEqual(snap.lines[1].usedPercent, 5)
        XCTAssertEqual(snap.fetchedAt.timeIntervalSince1970, written, accuracy: 0.001)
        XCTAssertEqual(snap.lastAPIFetch.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 0.001)

        // A current file stretches the API interval from 5 to 30 min: 20 min since the last API read (above) was
        // not due, 60 min is.
        var stale = try XCTUnwrap(store.states[.claude])
        stale.snapshot?.apiFetchedAt = Date().addingTimeInterval(-60 * 60)
        XCTAssertTrue(store.shouldFetch(.claude, state: stale, manual: false, now: Date()))
    }
}
