import Foundation
import XCTest
@testable import QuotaBarCore

final class ToolingInventoryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tooling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scan() -> ToolingInventory { ToolingScanner.scan(home: home, env: [:]) }

    func testEmptyHomeMarksEveryToolNotInstalled() {
        let inv = scan()
        XCTAssertEqual(inv.notInstalled, Set(ToolID.allCases))
        XCTAssertTrue(inv.items.isEmpty)
    }

    func testClaudeSkillIsSharedWithOpenCode() throws {
        try write(".claude/skills/demo/SKILL.md", "---\nname: demo\ndescription: Does demo things\n---\nbody")
        try write(".claude/skills/not-a-skill/readme.txt", "x")
        let inv = scan()
        let claude = inv.items(for: .claudeCode, kind: .skill)
        let opencode = inv.items(for: .opencode, kind: .skill)
        XCTAssertEqual(claude.map(\.name), ["demo"])
        XCTAssertEqual(claude.first?.detail, "Does demo things")
        XCTAssertEqual(claude.first?.sharedWith, [.opencode])
        XCTAssertEqual(opencode.first?.sharedWith, [.claudeCode])
    }

    func testOpenCodeMcpAndPluginsNeverExposeSecrets() throws {
        try write(".config/opencode/opencode.json", """
        {"plugin":["./plugins/cmux","some-npm-plugin"],
         "mcp":{"remote1":{"type":"remote","url":"https://mcp.example.com/path?token=SECRET123","headers":{"Authorization":"Bearer SECRET456"}},
                "local1":{"type":"local","command":["/usr/bin/node","server.js","--key=SECRET789"],"environment":{"API_KEY":"SECRET000"},"enabled":false}}}
        """)
        try write(".config/opencode/plugins/auto.js", "export default {}")
        let inv = scan()

        let mcp = inv.items(for: .opencode, kind: .mcp)
        XCTAssertEqual(mcp.map(\.name), ["local1", "remote1"])
        XCTAssertEqual(mcp.first { $0.name == "local1" }?.status, .disabled)
        XCTAssertEqual(mcp.first { $0.name == "remote1" }?.detail, "remote · mcp.example.com")
        XCTAssertEqual(mcp.first { $0.name == "local1" }?.detail, "local · node")
        let everything = inv.items.map { "\($0.name) \($0.detail) \($0.location ?? "")" }.joined()
        XCTAssertFalse(everything.contains("SECRET"))

        let plugins = inv.items(for: .opencode, kind: .plugin).map(\.name)
        XCTAssertTrue(plugins.contains("cmux"))
        XCTAssertTrue(plugins.contains("some-npm-plugin"))
        XCTAssertTrue(plugins.contains("auto.js"))
    }

    func testClaudeMcpAndPluginEnabledFlags() throws {
        try write(".claude.json", #"{"mcpServers":{"stitch":{"type":"http","url":"https://stitch.example.com/mcp","headers":{"X-Key":"SECRET"}}}}"#)
        try write(".claude/settings.json", #"{"enabledPlugins":{"a@m":true,"b@m":false}}"#)
        try write(".claude/plugins/installed_plugins.json", #"{"plugins":{"a@m":[{"version":"1.2.3"}]}}"#)
        let inv = scan()
        XCTAssertEqual(inv.items(for: .claudeCode, kind: .mcp).first?.detail, "http · stitch.example.com")
        let plugins = inv.items(for: .claudeCode, kind: .plugin)
        XCTAssertEqual(plugins.first { $0.name == "a@m" }?.status, .enabled)
        XCTAssertEqual(plugins.first { $0.name == "a@m" }?.detail, "v1.2.3")
        XCTAssertEqual(plugins.first { $0.name == "b@m" }?.status, .disabled)
        XCTAssertFalse(inv.items.map(\.detail).joined().contains("SECRET"))
    }

    func testCodexTomlMcpOnlyReadsHeadersAndSafeKeys() throws {
        try write(".codex/config.toml", """
        model = "x"
        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "pkg"]
        env = { TOKEN = "SECRET" }

        [mcp_servers.off]
        url = "https://off.example.com/mcp"
        enabled = false

        [mcp_servers.docs.env]
        TOKEN = "SECRET2"
        """)
        let inv = scan()
        XCTAssertFalse(inv.notInstalled.contains(.codex))
        let mcp = inv.items(for: .codex, kind: .mcp)
        XCTAssertEqual(mcp.map(\.name), ["docs", "off"])
        XCTAssertEqual(mcp.first { $0.name == "docs" }?.detail, "local · npx")
        XCTAssertEqual(mcp.first { $0.name == "off" }?.status, .disabled)
        XCTAssertFalse(inv.items.map(\.detail).joined().contains("SECRET"))
    }

    func testJSONCCommentsAreValidAndOnlyRealBreakageWarns() throws {
        try write(".config/opencode/opencode.jsonc", """
        {
          // OpenCode allows comments
          "plugins": ["pkg-a", { "package": "./plugins/local" }],
        }
        """)
        var inv = scan()
        XCTAssertTrue(inv.warnings.isEmpty)
        XCTAssertEqual(inv.items(for: .opencode, kind: .plugin).map(\.name).sorted(), ["local", "pkg-a"])

        try write(".config/opencode/opencode.json", "{ broken")
        inv = scan()
        XCTAssertFalse(inv.warnings.isEmpty)
    }

    func testOpenCodeV2ServersShapeAndDisabledFlag() throws {
        try write(".config/opencode/opencode.json", """
        {"mcp": {"timeout": {"startup": 1000},
                 "servers": {"on": {"type": "remote", "url": "https://a.example.com/mcp"},
                             "off": {"type": "local", "command": ["npx", "x"], "disabled": true}}}}
        """)
        let inv = scan()
        let mcp = inv.items(for: .opencode, kind: .mcp)
        XCTAssertEqual(mcp.map(\.name), ["off", "on"])
        XCTAssertEqual(mcp.first { $0.name == "off" }?.status, .disabled)
        XCTAssertEqual(mcp.first { $0.name == "on" }?.spec, "mcp.servers.on")
        XCTAssertFalse(mcp.contains { $0.name == "timeout" }, "mcp.timeout is not a server")
    }

    func testLegacyV1McpShapeStillRecognised() throws {
        try write(".config/opencode/opencode.json", #"{"mcp":{"jira":{"type":"remote","url":"https://j.example.com/mcp","enabled":false}}}"#)
        let inv = scan()
        let item = try XCTUnwrap(inv.items(for: .opencode, kind: .mcp).first)
        XCTAssertEqual(item.name, "jira")
        XCTAssertEqual(item.status, .disabled)
        XCTAssertEqual(item.spec, "mcp.jira")
    }

    func testScanningNeverModifiesAnyFile() throws {
        try write(".claude/skills/demo/SKILL.md", "---\nname: demo\n---")
        try write(".config/opencode/opencode.json", #"{"plugin":[]}"#)
        func snapshot() -> [String: Date] {
            var out: [String: Date] = [:]
            let e = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.contentModificationDateKey])
            while let url = e?.nextObject() as? URL {
                out[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            return out
        }
        let before = snapshot()
        _ = scan()
        XCTAssertEqual(before, snapshot())
    }
}
