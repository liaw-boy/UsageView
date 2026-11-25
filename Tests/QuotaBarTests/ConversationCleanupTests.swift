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

    func testMoveToTrashRejectsPathsOutsideDataFoldersAndSymlinks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("trash-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("codex")
        let outside = root.appendingPathComponent("outside.jsonl")
        let link = home.appendingPathComponent("sessions/link.jsonl")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "data".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        let manager = ConversationManager(codexHome: home)
        let now = Date()
        for path in [outside.path, link.path] {
            let s = ConversationSession(
                id: "x", provider: .codex, projectName: "demo", projectPath: "", prompt: "p",
                createdAt: now, updatedAt: now, totalSizeBytes: 4, mainFilePath: path
            )
            do {
                _ = try await manager.moveToTrash(session: s)
                XCTFail("should reject \(path)")
            } catch {}
        }
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
        XCTAssertTrue(fm.fileExists(atPath: link.path))
    }

    func testAntigravityScannerFindsStandardSessionsAndSkipsBackups() async throws {
        let fm = FileManager.default
        let geminiRoot = fm.temporaryDirectory.appendingPathComponent("gemini-" + UUID().uuidString)
        defer { try? fm.removeItem(at: geminiRoot) }

        let convDir = geminiRoot.appendingPathComponent("antigravity/conversations")
        let brainLogs = geminiRoot.appendingPathComponent("antigravity/brain/conv-1234/.system_generated/logs")
        let backupConvDir = geminiRoot.appendingPathComponent("antigravity-backup/conversations")
        try fm.createDirectory(at: convDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: brainLogs, withIntermediateDirectories: true)
        try fm.createDirectory(at: backupConvDir, withIntermediateDirectories: true)

        try Data("sqlite-bytes".utf8).write(to: convDir.appendingPathComponent("conv-1234.db"))
        try Data("wal-bytes".utf8).write(to: convDir.appendingPathComponent("conv-1234.db-wal"))
        try Data("backup-bytes".utf8).write(to: backupConvDir.appendingPathComponent("old-backup.db"))
        let transcript = """
        {"type":"USER_INPUT","created_at":"2026-05-01T10:00:00Z","content":"<USER_REQUEST>Fix the build</USER_REQUEST>"}
        {"type":"PLANNER_RESPONSE","created_at":"2026-05-01T10:01:00Z","content":"Build fixed."}
        """
        try transcript.write(to: brainLogs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let manager = ConversationManager(geminiRoot: geminiRoot)
        let found = await manager.scanAntigravitySessions()
        XCTAssertEqual(found.count, 1)
        let session = try XCTUnwrap(found.first)
        XCTAssertEqual(session.id, "conv-1234")
        XCTAssertEqual(session.prompt, "Fix the build")
        XCTAssertNotNil(session.subagentDirPath)

        let preview = await manager.loadPreviewMessages(session: session, limit: 10)
        XCTAssertEqual(preview.map(\.role), ["User", "Antigravity"])
        XCTAssertEqual(preview.map(\.text), ["Fix the build", "Build fixed."])
    }

    func testCodexPreviewAndExportMessages() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("codex-preview-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let dayDir = home.appendingPathComponent("sessions/2026/05/01")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let rollout = """
        {"type":"session_meta","timestamp":"2026-05-01T10:00:00Z","payload":{"cwd":"/work/demo-app"}}
        {"type":"response_item","timestamp":"2026-05-01T10:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>skip me</environment_context>"}]}}
        {"type":"response_item","timestamp":"2026-05-01T10:00:02Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Explain this crash"}]}}
        {"type":"response_item","timestamp":"2026-05-01T10:00:05Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The crash is caused by a nil unwrap."}]}}
        """
        try rollout.write(to: dayDir.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)

        let manager = ConversationManager(codexHome: home)
        let sessions = await manager.scanCodexSessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.prompt, "Explain this crash")

        let preview = await manager.loadPreviewMessages(session: session, limit: 10)
        XCTAssertEqual(preview.map(\.role), ["User", "Codex"])
        XCTAssertEqual(preview.map(\.text), ["Explain this crash", "The crash is caused by a nil unwrap."])

        let exported = await manager.loadAllMessagesForExport(session: session)
        XCTAssertEqual(exported.count, 2)
    }
}
