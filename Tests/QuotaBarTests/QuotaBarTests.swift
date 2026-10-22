import Foundation
import XCTest
@testable import QuotaBarCore

final class QuotaBarTests: XCTestCase {

    // MARK: - 1. EndpointGuard (Zero-Quota Safety Guarantee)

    func testAllowlistPermitsReadOnlyUsageEndpoints() throws {
        let allowed: [(String, String)] = [
            ("GET", "https://api.anthropic.com/api/oauth/usage"),
            ("GET", "https://chatgpt.com/backend-api/wham/usage"),
            ("POST", "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"),
            ("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"),
            ("GET", "https://api.github.com/repos/liaw-boy/quotabar/releases/latest"),
        ]
        for (method, urlString) in allowed {
            var req = URLRequest(url: URL(string: urlString)!)
            req.httpMethod = method
            XCTAssertNoThrow(try EndpointGuard.validate(req), "Should allow \(method) \(urlString)")
        }
    }

    func testAllowlistBlocksInferenceResetAndTokenRotationEndpoints() {
        let forbidden: [(String, String)] = [
            // Model inference (consumes quota!)
            ("POST", "https://api.anthropic.com/v1/messages"),
            ("POST", "https://api.openai.com/v1/responses"),
            ("POST", "https://cloudcode-pa.googleapis.com/v1internal:generateContent"),
            // Rate-limit reset / credit consumption
            ("GET", "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"),
            ("POST", "https://api.anthropic.com/api/organizations/123/reset_rate_limits"),
            ("POST", "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"),
            // Rotating OAuth token refresh (would log out user's CLI!)
            ("POST", "https://platform.claude.com/v1/oauth/token"),
            ("POST", "https://auth.openai.com/oauth/token"),
            ("POST", "https://oauth2.googleapis.com/token"),
            // Wrong method or plain HTTP
            ("POST", "https://api.anthropic.com/api/oauth/usage"),
            ("GET", "http://api.anthropic.com/api/oauth/usage"),
        ]
        for (method, urlString) in forbidden {
            var req = URLRequest(url: URL(string: urlString)!)
            req.httpMethod = method
            XCTAssertThrowsError(try EndpointGuard.validate(req), "Must block \(method) \(urlString)")
        }
    }

    // MARK: - 2. Provider Mappers

    func testClaudeMapper() throws {
        let body: [String: Any] = [
            "five_hour": ["utilization": 42.5, "resets_at": "2026-10-22T08:00:00Z"],
            "seven_day": ["utilization": 18.0, "resets_at": "2026-10-27T00:00:00Z"],
        ]
        let lines = try ClaudeMapper.map(body)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].kind, .session)
        XCTAssertEqual(lines[0].usedPercent, 42.5)
        XCTAssertEqual(lines[1].kind, .weekly)
        XCTAssertEqual(lines[1].usedPercent, 18.0)
    }

    func testCodexMapperClassifiesByDurationNotSlot() throws {
        // Codex sometimes puts the weekly window into primary_window when 5h is absent.
        let body: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 65,
                    "limit_window_seconds": 604800,
                    "reset_at": 1_792_700_000,
                ],
                "secondary_window": [
                    "used_percent": 12,
                    "limit_window_seconds": 18000,
                    "reset_at": 1_792_650_000,
                ],
            ]
        ]
        let lines = try CodexMapper.map(body)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].kind, .session)
        XCTAssertEqual(lines[0].usedPercent, 12)
        XCTAssertEqual(lines[1].kind, .weekly)
        XCTAssertEqual(lines[1].usedPercent, 65)
    }

    func testAntigravityMapperMergesHostsAndDetectsNotStarted() {
        // Host 1 returns only Gemini; Host 2 returns Claude/GPT (3p). First usable bucket wins.
        let host1: [String: Any] = [
            "groups": [[
                "buckets": [
                    ["bucketId": "gemini-5h", "remainingFraction": 1.0], // no resetTime -> Not started
                    ["bucketId": "gemini-weekly", "remainingFraction": 0.75, "resetTime": "2026-10-28T00:00:00Z"],
                ]
            ]]
        ]
        let host2: [String: Any] = [
            "response": ["groups": [[
                "buckets": [
                    ["bucketId": "gemini-weekly", "remainingFraction": 0.10], // duplicate, ignored
                    ["bucketId": "3p-5h", "remainingFraction": 0.60, "resetTime": "2026-10-22T09:00:00Z"],
                    ["bucketId": "3p-weekly", "remainingFraction": 0.80, "resetTime": "2026-10-28T00:00:00Z"],
                ]
            ]]]
        ]
        let lines = AntigravityMapper.map([host1, host2])
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].isNotStarted)
        XCTAssertEqual(lines[1].usedPercent, 25, accuracy: 0.01)
        XCTAssertEqual(lines[2].usedPercent, 40, accuracy: 0.01)
        XCTAssertEqual(lines[3].usedPercent, 20, accuracy: 0.01)
    }

    // MARK: - 3. Store: Stale-While-Revalidate & 429 Backoff

    @MainActor
    func testFailedRefreshPreservesPreviousSnapshotAndApplies429Backoff() async {
        struct MockRuntime: ProviderRuntime {
            let id = ProviderID.claude
            let handler: @Sendable () throws -> [MetricLine]
            func fetch() async throws -> [MetricLine] { try handler() }
        }

        let box = LockedBox(shouldFail: false)
        let runtime = MockRuntime {
            if box.shouldFail {
                throw ProviderError.rateLimited(retryAfter: 600)
            }
            return [MetricLine(id: "5h", label: "5 小時", kind: .session, usedPercent: 33, resetsAt: nil)]
        }

        let tmpCache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SnapshotStore(runtimes: [runtime], settings: settings, cacheURL: tmpCache)

        await store.refresh()
        XCTAssertEqual(store.states[.claude]?.snapshot?.sessionPercent, 33)
        XCTAssertNil(store.states[.claude]?.error)

        box.shouldFail = true
        await store.refresh()
        // Previous snapshot is preserved ("stale-while-revalidate") and backoff is scheduled.
        XCTAssertEqual(store.states[.claude]?.snapshot?.sessionPercent, 33)
        XCTAssertNotNil(store.states[.claude]?.error)
        XCTAssertEqual(store.states[.claude]?.isStale, true)
        XCTAssertNotNil(store.backoffUntil(.claude))
    }

    @MainActor
    func testIndependentTrackingPanelAndMenuBarSettings() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        // Initially all 3 are tracked, shown in panel, and shown in menu bar.
        XCTAssertTrue(settings.isTracked(.claude))
        XCTAssertTrue(settings.isShownInPanel(.claude))
        XCTAssertTrue(settings.isShownInMenuBar(.claude))

        // Hide Codex from menu bar only -> still tracked and shown in panel.
        settings.setShownInMenuBar(.codex, false)
        XCTAssertTrue(settings.isTracked(.codex))
        XCTAssertTrue(settings.isShownInPanel(.codex))
        XCTAssertFalse(settings.isShownInMenuBar(.codex))

        // Disable tracking for Antigravity -> cascades off in panel and menu bar.
        settings.setTracked(.antigravity, false)
        XCTAssertFalse(settings.isTracked(.antigravity))
        XCTAssertFalse(settings.isShownInPanel(.antigravity))
        XCTAssertFalse(settings.isShownInMenuBar(.antigravity))

        // Re-enabling menu bar for Antigravity automatically turns tracking back on.
        settings.setShownInMenuBar(.antigravity, true)
        XCTAssertTrue(settings.isTracked(.antigravity))
        XCTAssertTrue(settings.isShownInMenuBar(.antigravity))
    }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldFail: Bool
    init(shouldFail: Bool) { _shouldFail = shouldFail }
    var shouldFail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _shouldFail }
        set { lock.lock(); defer { lock.unlock() }; _shouldFail = newValue }
    }
}
