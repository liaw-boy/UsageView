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
            ("POST", "https://oauth2.googleapis.com/token"),
            ("GET", "https://api.github.com/repos/liaw-boy/UsageView/releases/latest"),
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
        // Host 1 (e.g. cloudcode-pa) has untouched Gemini (1.0) and 3p buckets;
        // Host 2 (e.g. daily-cloudcode-pa) has real Gemini usage + optional Gemini 4 Argon group.
        // Higher usedPercent (lower remainingFraction) wins across hosts.
        let host1: [String: Any] = [
            "groups": [[
                "buckets": [
                    ["bucketId": "gemini-5h", "remainingFraction": 1.0], // no resetTime -> Not started
                    ["bucketId": "gemini-weekly", "remainingFraction": 1.0],
                    ["bucketId": "3p-5h", "remainingFraction": 0.60, "resetTime": "2026-10-22T09:00:00Z"],
                    ["bucketId": "3p-weekly", "remainingFraction": 0.80, "resetTime": "2026-10-28T00:00:00Z"],
                ]
            ]]
        ]
        let host2: [String: Any] = [
            "response": ["groups": [
                [
                    "buckets": [
                        ["bucketId": "gemini-weekly", "remainingFraction": 0.75, "resetTime": "2026-10-28T00:00:00Z"],
                    ]
                ],
                [
                    "displayName": "Gemini 4 Argon",
                    "buckets": [
                        ["window": "weekly", "remainingFraction": 0.50, "resetTime": "2026-10-28T00:00:00Z"],
                    ]
                ]
            ]]
        ]
        let lines = AntigravityMapper.map([host1, host2])
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].isNotStarted)
        XCTAssertEqual(lines[1].usedPercent, 25, accuracy: 0.01) // 0.75 from host2 beats 1.0 from host1
        XCTAssertEqual(lines[2].id, "argon-weekly")
        XCTAssertEqual(lines[2].usedPercent, 50, accuracy: 0.01)
        XCTAssertEqual(lines[3].usedPercent, 40, accuracy: 0.01)
        XCTAssertEqual(lines[4].usedPercent, 20, accuracy: 0.01)

        // Verify Antigravity's headline sessionPercent & weeklyPercent always use Gemini pool, not Claude/GPT (3p)
        let snap = ProviderSnapshot(provider: .antigravity, lines: lines)
        XCTAssertEqual(snap.sessionPercent ?? -1, 0, accuracy: 0.01)   // Gemini 5h is 0% (not 3p's 40%)
        XCTAssertEqual(snap.weeklyPercent ?? -1, 25, accuracy: 0.01)   // Gemini weekly is 25%
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
        // 1. Restarting the store (or calling automatic refresh before `refreshMinutes` elapses)
        // must NOT re-call the API when the persisted cache is still fresh!
        let restartedStore = SnapshotStore(runtimes: [runtime], settings: settings, cacheURL: tmpCache)
        await restartedStore.refresh(manual: false)
        XCTAssertEqual(restartedStore.states[.claude]?.snapshot?.sessionPercent, 33)
        XCTAssertNil(restartedStore.states[.claude]?.error)

        // 2. When the cached snapshot is older than `refreshMinutes` (e.g. 10m ago), automatic refresh runs,
        // and on 429 failure it preserves the previous snapshot ("stale-while-revalidate") and schedules backoff.
        let expiredSnap = [ProviderSnapshot(
            provider: .claude,
            lines: [MetricLine(id: "5h", label: "5 小時", kind: .session, usedPercent: 33, resetsAt: nil)],
            fetchedAt: Date().addingTimeInterval(-600)
        )]
        try? JSONEncoder().encode(expiredSnap).write(to: tmpCache)
        let dueStore = SnapshotStore(runtimes: [runtime], settings: settings, cacheURL: tmpCache)
        await dueStore.refresh(manual: false)
        XCTAssertEqual(dueStore.states[.claude]?.snapshot?.sessionPercent, 33)
        XCTAssertNotNil(dueStore.states[.claude]?.error)
        XCTAssertEqual(dueStore.states[.claude]?.isStale, true)
        XCTAssertNotNil(dueStore.backoffUntil(.claude))
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

    func testPlanAndExtraUsageFormatting() {
        XCTAssertEqual(ClaudeMapper.formatPlan(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(ClaudeMapper.formatPlan(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(ClaudeMapper.formatPlan(subscriptionType: "pro", rateLimitTier: nil), "Pro")

        let claudeExtra: [String: Any] = ["extra_usage": ["is_enabled": true, "used_credits": 1250, "monthly_limit": 5000]]
        XCTAssertEqual(ClaudeMapper.formatExtraUsage(claudeExtra), "額外用量 $12.50 / $50")

        XCTAssertEqual(CodexMapper.formatPlan("plus"), "Plus")
        XCTAssertEqual(CodexMapper.formatPlan("pro"), "Pro 200")
        XCTAssertEqual(CodexMapper.formatPlan("promax"), "Pro 500")
        XCTAssertEqual(CodexMapper.formatCredits(["credits": ["balance": 320.0]]), "點數餘額 $12.80 · 320 點")

        XCTAssertEqual(AntigravityMapper.parsePlan(from: ["paidTier": ["id": "g1-ultra-tier"]]), "Ultra")
        XCTAssertEqual(AntigravityMapper.parsePlan(from: ["paidTier": ["id": "g1-pro-tier"]]), "Pro")
    }

    func testTimeElapsedTickAndBurnRateProjection() {
        let now = Date()
        // 50% of 5-hour window elapsed (2.5h left), 25% used -> projected 50% at reset (~50% spare)
        let comfortableLine = MetricLine(
            id: "5h",
            label: "5 小時",
            kind: .session,
            usedPercent: 25,
            resetsAt: now.addingTimeInterval(2.5 * 3600),
            periodSeconds: 5 * 3600
        )
        XCTAssertEqual(comfortableLine.timeElapsedFraction(now: now) ?? 0, 0.50, accuracy: 0.01)
        let proj1 = comfortableLine.projectionText(now: now)
        XCTAssertEqual(proj1?.isWarning, false)
        XCTAssertEqual(proj1?.text, "預計剩 ~50%")

        // 50% of 5-hour window elapsed (2.5h left), 80% used -> projected 160% -> runs out early!
        let fastBurnLine = MetricLine(
            id: "5h",
            label: "5 小時",
            kind: .session,
            usedPercent: 80,
            resetsAt: now.addingTimeInterval(2.5 * 3600),
            periodSeconds: 5 * 3600
        )
        let proj2 = fastBurnLine.projectionText(now: now)
        XCTAssertEqual(proj2?.isWarning, true)
        XCTAssertTrue(proj2?.text.contains("後耗盡") == true)
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
