import Foundation
import XCTest
@testable import QuotaBarCore

final class ConversationCleanupTests: XCTestCase {

    private func session(_ id: String, provider: ProviderID = .claude, daysOld: Double, mb: Int, now: Date) -> ConversationSession {
        ConversationSession(
            id: id, provider: provider, projectName: "demo", projectPath: "/tmp/demo", prompt: "p",
            createdAt: now, updatedAt: now.addingTimeInterval(-daysOld * 86400),
            totalSizeBytes: Int64(mb) * 1024 * 1024, mainFilePath: "/tmp/\(id).jsonl"
        )
    }

    func testCleanupCandidatesRespectConfiguredAgeAndSize() {
        let now = Date()
        let all = [
            session("old-big", daysOld: 20, mb: 80, now: now),
            session("old-small", daysOld: 20, mb: 5, now: now),
            session("new-big", daysOld: 2, mb: 500, now: now),
            session("codex-old-big", provider: .codex, daysOld: 40, mb: 60, now: now),
        ]
        let defaults = ConversationManager.cleanupCandidates(from: all, minAgeDays: 14, minSizeMB: 50, now: now).map(\.id)
        XCTAssertEqual(Set(defaults), ["old-big", "codex-old-big"])

        let loose = ConversationManager.cleanupCandidates(from: all, minAgeDays: 1, minSizeMB: 1, now: now).map(\.id)
        XCTAssertEqual(Set(loose), Set(all.map(\.id)))

        let strict = ConversationManager.cleanupCandidates(from: all, minAgeDays: 30, minSizeMB: 50, now: now).map(\.id)
        XCTAssertEqual(strict, ["codex-old-big"])
    }

    @MainActor
    func testCleanupSettingsDefaultsPersistAndClamp() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let fresh = SettingsStore(defaults: defaults)
        XCTAssertEqual(fresh.cleanupMinAgeDays, 14)
        XCTAssertEqual(fresh.cleanupMinSizeMB, 50)

        fresh.cleanupMinAgeDays = 30
        fresh.cleanupMinSizeMB = 100
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.cleanupMinAgeDays, 30)
        XCTAssertEqual(reloaded.cleanupMinSizeMB, 100)

        defaults.set(-5, forKey: "cleanupMinAgeDays")
        defaults.set(999_999, forKey: "cleanupMinSizeMB")
        let clamped = SettingsStore(defaults: defaults)
        XCTAssertEqual(clamped.cleanupMinAgeDays, 1)
        XCTAssertEqual(clamped.cleanupMinSizeMB, 5000)
    }

    func testCodexScannerFindsSessionsAndArchivedWithMetadata() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dayDir = home.appendingPathComponent("sessions/2026/01/02")
        let archived = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        let rollout = """
        {"type":"session_meta","timestamp":"2026-01-02T03:04:05.000Z","payload":{"cwd":"/work/demo-app","timestamp":"2026-01-02T03:04:05.000Z"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>ignored</environment_context>"}]}}
        {"type":"event_msg","payload":{"type":"user_message","message":"Add a login page"}}

        """
        try rollout.write(to: dayDir.appendingPathComponent("rollout-2026-01-02T03-04-05-aaaa1111.jsonl"), atomically: true, encoding: .utf8)
        try "{\"type\":\"session_meta\",\"payload\":{}}\n".write(to: archived.appendingPathComponent("rollout-old.jsonl"), atomically: true, encoding: .utf8)
        try "not a session".write(to: dayDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let found = await ConversationManager(codexHome: home).scanCodexSessions()
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { $0.provider == .codex && $0.subagentDirPath == nil })

        let main = try XCTUnwrap(found.first { $0.id.hasSuffix("aaaa1111") })
        XCTAssertEqual(main.projectName, "demo-app")
        XCTAssertEqual(main.projectPath, "/work/demo-app")
        XCTAssertEqual(main.prompt, "Add a login page")
        XCTAssertGreaterThan(main.totalSizeBytes, 0)

        let fallback = try XCTUnwrap(found.first { $0.id == "rollout-old" })
        XCTAssertEqual(fallback.projectName, "Codex")
        XCTAssertTrue(fallback.prompt.hasPrefix("對話"))
    }
}
