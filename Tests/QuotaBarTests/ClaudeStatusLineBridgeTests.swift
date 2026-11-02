import Foundation
import XCTest
@testable import QuotaBarCore

final class ClaudeStatusLineBridgeTests: XCTestCase {
    private func tempClaudeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func settings(_ bridge: ClaudeStatusLineBridge) throws -> [String: Any] {
        try XCTUnwrap(Parse.object(try Data(contentsOf: bridge.settingsURL)))
    }

    func testInstallWrapsExistingStatusLineAndUninstallRestoresIt() throws {
        let dir = try tempClaudeDir()
        let bridge = ClaudeStatusLineBridge(claudeDir: dir)
        let original: [String: Any] = ["model": "example", "statusLine": ["type": "command", "command": "echo hi", "padding": 2]]
        try JSONSerialization.data(withJSONObject: original).write(to: bridge.settingsURL)

        try bridge.install()
        try bridge.install() // idempotent: must not wrap itself

        let line = try XCTUnwrap(try settings(bridge)["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, ClaudeStatusLineBridge.command)
        XCTAssertEqual(line["padding"] as? Int, 2)
        XCTAssertEqual(try settings(bridge)["model"] as? String, "example")
        XCTAssertEqual(try String(contentsOf: bridge.nextURL, encoding: .utf8), "echo hi")
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("usageview-bak") }
        XCTAssertEqual(backups.count, 1)

        try bridge.uninstall()
        let restored = try settings(bridge)
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "echo hi")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.nextURL.path))
    }

    func testInstallWithoutStatusLineThenUninstallRemovesIt() throws {
        let bridge = ClaudeStatusLineBridge(claudeDir: try tempClaudeDir())
        try bridge.install() // no settings.json yet
        XCTAssertTrue(ClaudeStatusLineBridge.isOurs(try settings(bridge)["statusLine"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.nextURL.path))
        try bridge.uninstall()
        XCTAssertNil(try settings(bridge)["statusLine"])
    }

    func testStatusLineTheUserSwitchedToIsNotWrappedAgain() throws {
        let bridge = ClaudeStatusLineBridge(claudeDir: try tempClaudeDir())
        try bridge.install()
        let mine: [String: Any] = ["statusLine": ["type": "command", "command": "echo mine"]]
        try JSONSerialization.data(withJSONObject: mine).write(to: bridge.settingsURL)

        try bridge.install() // next app launch
        XCTAssertEqual((try settings(bridge)["statusLine"] as? [String: Any])?["command"] as? String, "echo mine")

        try bridge.uninstall() // setting off, then on again: wraps the new one
        try bridge.install()
        XCTAssertTrue(ClaudeStatusLineBridge.isOurs(try settings(bridge)["statusLine"]))
        XCTAssertEqual(try String(contentsOf: bridge.nextURL, encoding: .utf8), "echo mine")
    }

    func testSymlinkedSettingsStaysASymlinkAndBackupIsARealCopy() throws {
        let dir = try tempClaudeDir()
        let dotfiles = dir.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"model":"example"}"#.utf8).write(to: dotfiles)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles)

        try ClaudeStatusLineBridge(claudeDir: dir).install()

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), dotfiles.path)
        XCTAssertTrue(ClaudeStatusLineBridge.isOurs(Parse.object(try Data(contentsOf: dotfiles))?["statusLine"]))
        let backup = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.contains("usageview-bak") })
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(backup).path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
    }

    func testMissingClaudeDirAndBrokenSettingsAreLeftAlone() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ClaudeStatusLineBridge(claudeDir: missing).install()
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let bridge = ClaudeStatusLineBridge(claudeDir: try tempClaudeDir())
        try Data("{ not json".utf8).write(to: bridge.settingsURL)
        XCTAssertThrowsError(try bridge.install())
        XCTAssertEqual(try String(contentsOf: bridge.settingsURL, encoding: .utf8), "{ not json")
    }

    func testScriptWritesLimitsAndRunsThePreviousStatusLine() throws {
        let dir = try tempClaudeDir()
        let bridge = ClaudeStatusLineBridge(claudeDir: dir)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "cat >/dev/null; echo previous-line"]])
            .write(to: bridge.settingsURL)
        try bridge.install()

        func run(_ input: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [bridge.scriptURL.path]
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            try p.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            p.waitUntilExit()
            return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        XCTAssertEqual(try run(#"{"model":{"display_name":"X"}}"#), "previous-line\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.limitsURL.path)) // no limits yet: nothing written

        XCTAssertEqual(try run(#"{"rate_limits":{"five_hour":{"used_percentage":7,"resets_at":1800000000}}}"#), "previous-line\n")
        let body = try XCTUnwrap(Parse.object(try Data(contentsOf: bridge.limitsURL)))
        let (_, lines) = try XCTUnwrap(ClaudeMapper.statusLineLimits(body))
        XCTAssertEqual(lines.first?.usedPercent, 7)
        XCTAssertEqual(body.keys.sorted(), ["rate_limits", "written_at"]) // nothing else from the status line input
        for url in [bridge.limitsURL, bridge.nextURL, bridge.scriptURL] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }
    }
}
