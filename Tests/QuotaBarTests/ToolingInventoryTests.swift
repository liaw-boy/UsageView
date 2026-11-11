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

    func testClaudeProjectScopedMcpIsListedReadOnly() throws {
        let proj = home.appendingPathComponent("work/demo-app").path
        try write(".claude.json", """
        {"mcpServers":{"global1":{"type":"http","url":"https://g.example.com/mcp"}},
         "projects":{"\(proj)":{"mcpServers":{"local1":{"type":"stdio","command":"npx","env":{"TOKEN":"SECRET1"}}}},
                     "/nonexistent/other":{"mcpServers":{}}}}
        """)
        try write("work/demo-app/.mcp.json", #"{"mcpServers":{"shared1":{"type":"http","url":"https://s.example.com/x","headers":{"A":"SECRET2"}}}}"#)
        let mcp = scan().items(for: .claudeCode, kind: .mcp)
        XCTAssertEqual(mcp.map(\.name), ["global1", "local1", "shared1"])
        XCTAssertNil(mcp.first { $0.name == "global1" }?.source)
        XCTAssertEqual(mcp.first { $0.name == "local1" }?.source, "專案 · demo-app")
        XCTAssertEqual(mcp.first { $0.name == "local1" }?.detail, "stdio · npx")
        XCTAssertEqual(mcp.first { $0.name == "shared1" }?.source, "專案 · demo-app")
        XCTAssertFalse(mcp.map { $0.detail + ($0.location ?? "") }.joined().contains("SECRET"))
    }

    func testProjectMcpStatusFollowsApprovalsAndIdsStayUnique() throws {
        let proj = home.appendingPathComponent("work/demo-app").path
        try write(".claude.json", """
        {"mcpServers":{"same":{"type":"http","url":"https://a.example.com"}},
         "projects":{"\(proj)":{"mcpServers":{"same":{"command":"npx"},"off1":{"command":"npx"}},
                                "disabledMcpServers":["off1"],
                                "enabledMcpjsonServers":["ok1"],"disabledMcpjsonServers":["no1"]}}}
        """)
        try write("work/demo-app/.mcp.json", #"{"mcpServers":{"ok1":{"command":"a"},"no1":{"command":"b"},"ask1":{"command":"c"}}}"#)
        let mcp = scan().items(for: .claudeCode, kind: .mcp)
        XCTAssertEqual(Set(mcp.map(\.id)).count, mcp.count, "user and project MCP with the same name must not share an id")
        let status = Dictionary(mcp.filter { $0.source != nil }.map { ($0.name, $0.status) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(status["off1"], .disabled)
        XCTAssertEqual(status["ok1"], .enabled)
        XCTAssertEqual(status["no1"], .disabled)
        XCTAssertEqual(status["ask1"], .unknown)
    }

    func testProjectFoldersInProtectedLocationsAreNotRead() {
        XCTAssertTrue(ToolingScanner.isSafeToRead(projectPath: home.appendingPathComponent("code/app").path, home: home))
        XCTAssertFalse(ToolingScanner.isSafeToRead(projectPath: home.appendingPathComponent("Documents/app").path, home: home))
        XCTAssertFalse(ToolingScanner.isSafeToRead(projectPath: home.appendingPathComponent("Library/Mobile Documents/x").path, home: home))
        XCTAssertFalse(ToolingScanner.isSafeToRead(projectPath: "/Volumes/Share/app", home: home))
        XCTAssertFalse(ToolingScanner.isSafeToRead(projectPath: home.appendingPathComponent("Desktop/../Desktop/app").path, home: home))
        XCTAssertTrue(ToolingScanner.isSafeToRead(projectPath: home.appendingPathComponent("DesktopApps/app").path, home: home))
        XCTAssertFalse(ToolingScanner.isSafeToRead(projectPath: home.appendingPathComponent("Library/Containers/x").path, home: home))
        XCTAssertFalse(ToolingScanner.isSafeToRead(projectPath: home.appendingPathComponent("documents/app").path, home: home),
                       "case differences must not bypass the check")
    }

    func testSymlinkIntoProtectedFolderIsNotRead() throws {
        let target = home.appendingPathComponent("Documents/app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("code-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(ToolingScanner.isSafeToRead(projectPath: link.path, home: home))
    }

    func testSameFolderNameInTwoProjectsKeepsDistinctIds() throws {
        let a = home.appendingPathComponent("work/app").path, b = home.appendingPathComponent("side/app").path
        try write(".claude.json", """
        {"projects":{"\(a)":{"mcpServers":{"db":{"command":"npx"}}},"\(b)":{"mcpServers":{"db":{"command":"npx"}}}}}
        """)
        let mcp = scan().items(for: .claudeCode, kind: .mcp)
        XCTAssertEqual(mcp.count, 2)
        XCTAssertEqual(Set(mcp.map(\.id)).count, 2)
    }

    func testClaudePluginBundledItemsFollowPluginState() throws {
        let install = home.appendingPathComponent(".claude/plugins/cache/mkt/kit/1.0.0").path
        try write(".claude/plugins/installed_plugins.json", """
        {"plugins":{"kit@mkt":[{"version":"1.0.0","installPath":"\(install)"}],
                    "evil@mkt":[{"version":"1","installPath":"/etc"}]}}
        """)
        try write(".claude/settings.json", #"{"enabledPlugins":{"kit@mkt":false}}"#)
        try write(".claude/plugins/cache/mkt/kit/1.0.0/skills/kit-skill/SKILL.md", "---\nname: kit-skill\ndescription: d\n---")
        try write(".claude/plugins/cache/mkt/kit/1.0.0/agents/kit-agent.md", "---\nname: kit-agent\n---")
        try write(".claude/plugins/cache/mkt/kit/1.0.0/.mcp.json", #"{"mcpServers":{"kit-mcp":{"type":"http","url":"https://k.example.com/mcp?key=SECRET"}}}"#)
        let inv = scan()
        for kind in [ToolingKind.skill, .agent, .mcp] {
            let items = inv.items(for: .claudeCode, kind: kind)
            XCTAssertEqual(items.count, 1, "\(kind)")
            XCTAssertEqual(items.first?.source, "Plugin · kit")
            XCTAssertEqual(items.first?.status, .disabled)
        }
        XCTAssertEqual(inv.items(for: .claudeCode, kind: .mcp).first?.detail, "http · k.example.com")
    }

    func testClaudeSyncedSkillsAreDedupedAndReadOnly() throws {
        try write(".claude/skills/synced/bucket-a/web-tool/SKILL.md", "---\nname: web-tool\ndescription: first\n---")
        try write(".claude/skills/synced/bucket-b/web-tool/SKILL.md", "---\nname: web-tool\ndescription: second\n---")
        try write(".claude/skills/synced/bucket-b/notes/SKILL.md", "---\nname: notes\n---")
        let skills = scan().items(for: .claudeCode, kind: .skill)
        XCTAssertEqual(skills.map(\.name), ["notes", "web-tool"])
        XCTAssertTrue(skills.allSatisfy { $0.source == "claude.ai 同步" && $0.sharedWith.isEmpty })
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
