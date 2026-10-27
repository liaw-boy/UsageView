import Foundation

public enum ToolID: String, CaseIterable, Identifiable, Sendable {
    case opencode, claudeCode, codex
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opencode: "OpenCode"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public enum ToolingKind: String, CaseIterable, Identifiable, Sendable {
    case skill, mcp, plugin, agent
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .skill: "Skill"
        case .mcp: "MCP"
        case .plugin: "Plugin"
        case .agent: "Agent"
        }
    }
}

public enum ToolingStatus: Sendable, Equatable {
    case enabled, disabled, unknown
}

public struct ToolingItem: Identifiable, Sendable, Equatable {
    public var id: String { "\(tool.rawValue)|\(kind.rawValue)|\(name)|\(location ?? "")" }
    public let tool: ToolID
    public let kind: ToolingKind
    public let name: String
    /// One short, non-secret line (skill description, MCP type + host / executable name, plugin version…).
    public let detail: String
    /// Absolute path of the folder or file the item lives in (nil when it only exists as a config entry).
    public let location: String?
    public let status: ToolingStatus
    /// Other tools that read the very same item (e.g. a skill in `~/.claude/skills` is also read by OpenCode).
    public let sharedWith: [ToolID]
    /// Raw config identifier (OpenCode plugin specifier such as `file:///…` or an npm name).
    public var spec: String? = nil
}

public struct ToolingInventory: Sendable, Equatable {
    public var items: [ToolingItem] = []
    /// Tools whose config/data folder does not exist on this Mac.
    public var notInstalled: Set<ToolID> = []
    /// Config files that exist but could not be parsed (shown as a warning, never fatal).
    public var warnings: [String] = []

    public init() {}

    public func items(for tool: ToolID, kind: ToolingKind) -> [ToolingItem] {
        items.filter { $0.tool == tool && $0.kind == kind }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func count(for tool: ToolID, kind: ToolingKind) -> Int {
        items.filter { $0.tool == tool && $0.kind == kind }.count
    }
}

/// Read-only scan of what is installed for OpenCode, Claude Code and Codex.
/// Never writes anything and never loads secret values (MCP `env` / `headers` / tokens are not read into the model).
public enum ToolingScanner {
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> ToolingInventory {
        var inv = ToolingInventory()
        scanOpenCode(home: home, env: env, into: &inv)
        scanClaude(home: home, env: env, into: &inv)
        scanCodex(home: home, env: env, into: &inv)
        return inv
    }

    // MARK: - Paths

    private static func dir(_ envValue: String?, fallback: URL) -> URL {
        if let envValue, !envValue.isEmpty { return URL(fileURLWithPath: (envValue as NSString).expandingTildeInPath) }
        return fallback
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Reads JSON or JSONC (OpenCode allows comments and trailing commas in `opencode.json(c)`).
    private static func json(_ url: URL, warnings: inout [String]) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let obj = JSONCText.object(text) else {
            warnings.append("無法解析 \(url.lastPathComponent)（格式錯誤）")
            return nil
        }
        return obj
    }

    // MARK: - Skills / agents (folders and markdown files)

    private struct Frontmatter { var name: String?; var description: String? }

    private static func frontmatter(of url: URL) -> Frontmatter {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---") else { return Frontmatter() }
        var fm = Frontmatter()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if key == "name" { fm.name = value }
            if key == "description" { fm.description = value }
        }
        return fm
    }

    private static func skills(in root: URL) -> [(name: String, description: String, path: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { folder in
            let skillFile = folder.appendingPathComponent("SKILL.md")
            guard exists(skillFile) else { return nil }
            let fm = frontmatter(of: skillFile)
            return (fm.name ?? folder.lastPathComponent, fm.description ?? "", folder.path)
        }
    }

    private static func markdownAgents(in root: URL) -> [(name: String, description: String, path: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { $0.pathExtension == "md" }.map { file in
            let fm = frontmatter(of: file)
            return (fm.name ?? file.deletingPathExtension().lastPathComponent, fm.description ?? "", file.path)
        }
    }

    // MARK: - MCP detail without secrets

    /// "remote · host" or "local · executable" — never arguments, env or headers.
    static func mcpDetail(type: String?, url: String?, command: String?) -> String {
        if let url, let host = URL(string: url)?.host { return "\(type ?? "remote") · \(host)" }
        if let command {
            let exe = command.split(separator: " ").first.map(String.init) ?? command
            return "\(type ?? "local") · \((exe as NSString).lastPathComponent)"
        }
        return type ?? ""
    }

    // MARK: - OpenCode

    private static func scanOpenCode(home: URL, env: [String: String], into inv: inout ToolingInventory) {
        let base = dir(env["XDG_CONFIG_HOME"].map { $0 + "/opencode" }, fallback: home.appendingPathComponent(".config/opencode"))
        let claudeSkills = home.appendingPathComponent(".claude/skills")
        let agentsSkills = home.appendingPathComponent(".agents/skills")
        guard exists(base) || exists(claudeSkills) || exists(agentsSkills) else {
            inv.notInstalled.insert(.opencode)
            return
        }

        // OpenCode reads `opencode.json` or `opencode.jsonc`.
        var pluginNames: [String: String?] = [:] // specifier -> location
        for fileName in ["opencode.json", "opencode.jsonc"] {
            let configURL = base.appendingPathComponent(fileName)
            guard let cfg = json(configURL, warnings: &inv.warnings) else { continue }

            // V2: `plugins: [ "pkg", { "package": "./local" } ]`. V1 legacy: `plugin: [ … ]`.
            for entry in (cfg["plugins"] as? [Any] ?? []) + (cfg["plugin"] as? [Any] ?? []) {
                if let name = entry as? String { pluginNames[name] = .some(nil) }
                else if let obj = entry as? [String: Any], let name = obj["package"] as? String { pluginNames[name] = .some(nil) }
            }

            // V2: `mcp.servers.<name>`. V1 legacy: `mcp.<name>`. `mcp.timeout` is not a server.
            let mcpRoot = cfg["mcp"] as? [String: Any] ?? [:]
            let servers: [String: Any]
            let configPath: [String]
            if let v2 = mcpRoot["servers"] as? [String: Any] {
                servers = v2
                configPath = ["mcp", "servers"]
            } else {
                servers = mcpRoot.filter { key, value in
                    key != "timeout" && (value as? [String: Any])?.isEmpty == false
                }
                configPath = ["mcp"]
            }
            for (name, value) in servers {
                let m = value as? [String: Any] ?? [:]
                // V2 uses `disabled`; V1 used `enabled`.
                let off = (m["disabled"] as? Bool == true) || (m["enabled"] as? Bool == false)
                let command = (m["command"] as? [String])?.first ?? (m["command"] as? String)
                inv.items.append(ToolingItem(
                    tool: .opencode, kind: .mcp, name: name,
                    detail: mcpDetail(type: m["type"] as? String, url: m["url"] as? String, command: command),
                    location: configURL.path,
                    status: off ? .disabled : .enabled, sharedWith: [],
                    spec: (configPath + [name]).joined(separator: ".")))
            }
        }

        for file in ["tui.json", "cli.json"] {
            guard let cfg = json(base.appendingPathComponent(file), warnings: &inv.warnings) else { continue }
            for p in (cfg["plugin"] as? [String] ?? []) + (cfg["plugins"] as? [String] ?? []) where pluginNames[p] == nil {
                pluginNames[p] = .some(nil)
            }
        }
        for (spec, _) in pluginNames {
            let isFile = spec.hasPrefix("file://") || spec.hasPrefix("./") || spec.hasPrefix("/")
            let path: String? = spec.hasPrefix("file://") ? URL(string: spec)?.path
                : spec.hasPrefix("./") ? base.appendingPathComponent(String(spec.dropFirst(2))).path
                : spec.hasPrefix("/") ? spec : nil
            let name: String
            if isFile {
                let url = URL(fileURLWithPath: path ?? spec)
                let generic = ["index.js", "tui.js", "server.js", "plugin.js"]
                name = generic.contains(url.lastPathComponent) ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
            } else {
                name = spec
            }
            inv.items.append(ToolingItem(tool: .opencode, kind: .plugin, name: name,
                                         detail: isFile ? "本機檔案" : "套件", location: path,
                                         status: .enabled, sharedWith: [], spec: spec))
        }

        // Loose `.js` / `.ts` files directly inside `plugins/` are loaded automatically by OpenCode.
        let pluginsDir = base.appendingPathComponent("plugins")
        for file in (try? FileManager.default.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        where ["js", "ts"].contains(file.pathExtension) {
            inv.items.append(ToolingItem(tool: .opencode, kind: .plugin, name: file.lastPathComponent,
                                         detail: "plugins/ 資料夾自動載入", location: file.path,
                                         status: .enabled, sharedWith: []))
        }

        for s in skills(in: base.appendingPathComponent("skills")) {
            inv.items.append(ToolingItem(tool: .opencode, kind: .skill, name: s.name, detail: s.description,
                                         location: s.path, status: .enabled, sharedWith: []))
        }
        // OpenCode also reads these folders: `~/.claude/skills` is shared with Claude Code, `~/.agents/skills` with Codex.
        for s in skills(in: claudeSkills) {
            inv.items.append(ToolingItem(tool: .opencode, kind: .skill, name: s.name, detail: s.description,
                                         location: s.path, status: .enabled, sharedWith: [.claudeCode]))
        }
        for s in skills(in: agentsSkills) {
            inv.items.append(ToolingItem(tool: .opencode, kind: .skill, name: s.name, detail: s.description,
                                         location: s.path, status: .enabled, sharedWith: [.codex]))
        }
        for a in markdownAgents(in: base.appendingPathComponent("agents")) {
            inv.items.append(ToolingItem(tool: .opencode, kind: .agent, name: a.name, detail: a.description,
                                         location: a.path, status: .enabled, sharedWith: []))
        }
    }

    // MARK: - Claude Code

    private static func scanClaude(home: URL, env: [String: String], into inv: inout ToolingInventory) {
        let base = dir(env["CLAUDE_CONFIG_DIR"], fallback: home.appendingPathComponent(".claude"))
        let userJSON = home.appendingPathComponent(".claude.json")
        guard exists(base) || exists(userJSON) else {
            inv.notInstalled.insert(.claudeCode)
            return
        }

        for s in skills(in: base.appendingPathComponent("skills")) {
            inv.items.append(ToolingItem(tool: .claudeCode, kind: .skill, name: s.name, detail: s.description,
                                         location: s.path, status: .enabled,
                                         sharedWith: base.lastPathComponent == ".claude" ? [.opencode] : []))
        }
        for a in markdownAgents(in: base.appendingPathComponent("agents")) {
            inv.items.append(ToolingItem(tool: .claudeCode, kind: .agent, name: a.name, detail: a.description,
                                         location: a.path, status: .enabled, sharedWith: []))
        }

        if let cfg = json(userJSON, warnings: &inv.warnings) {
            for (name, value) in (cfg["mcpServers"] as? [String: Any]) ?? [:] {
                let m = value as? [String: Any] ?? [:]
                inv.items.append(ToolingItem(
                    tool: .claudeCode, kind: .mcp, name: name,
                    detail: mcpDetail(type: m["type"] as? String, url: m["url"] as? String, command: m["command"] as? String),
                    location: userJSON.path, status: .enabled, sharedWith: []))
            }
        }

        // Plugins: enabled flag from settings.json, version from installed_plugins.json
        var versions: [String: String] = [:]
        if let installed = json(base.appendingPathComponent("plugins/installed_plugins.json"), warnings: &inv.warnings),
           let plugins = installed["plugins"] as? [String: [[String: Any]]] {
            for (name, entries) in plugins { if let v = entries.first?["version"] as? String { versions[name] = v } }
        }
        if let settings = json(base.appendingPathComponent("settings.json"), warnings: &inv.warnings),
           let enabled = settings["enabledPlugins"] as? [String: Bool] {
            for (name, on) in enabled {
                inv.items.append(ToolingItem(tool: .claudeCode, kind: .plugin, name: name,
                                             detail: versions[name].map { "v\($0)" } ?? "",
                                             location: base.appendingPathComponent("settings.json").path,
                                             status: on ? .enabled : .disabled, sharedWith: []))
            }
        }
    }

    // MARK: - Codex

    private static func scanCodex(home: URL, env: [String: String], into inv: inout ToolingInventory) {
        let base = dir(env["CODEX_HOME"], fallback: home.appendingPathComponent(".codex"))
        let agentsSkills = home.appendingPathComponent(".agents/skills")
        guard exists(base) else {
            inv.notInstalled.insert(.codex)
            return
        }
        for s in skills(in: base.appendingPathComponent("skills")) {
            inv.items.append(ToolingItem(tool: .codex, kind: .skill, name: s.name, detail: s.description,
                                         location: s.path, status: .enabled, sharedWith: []))
        }
        for s in skills(in: agentsSkills) {
            inv.items.append(ToolingItem(tool: .codex, kind: .skill, name: s.name, detail: s.description,
                                         location: s.path, status: .enabled, sharedWith: [.opencode]))
        }
        // config.toml: only `[mcp_servers.<name>]` table headers plus their `command` / `url` / `enabled` keys.
        let toml = base.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return }
        var current: String?
        var fields: [String: [String: String]] = [:]
        var order: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                if header.hasPrefix("mcp_servers."), !header.dropFirst(12).contains(".") {
                    let name = String(header.dropFirst(12)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    current = name
                    if fields[name] == nil { fields[name] = [:]; order.append(name) }
                }
                continue
            }
            guard let name = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard ["command", "url", "enabled"].contains(key) else { continue }
            fields[name]?[key] = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        for name in order {
            let f = fields[name] ?? [:]
            inv.items.append(ToolingItem(
                tool: .codex, kind: .mcp, name: name,
                detail: mcpDetail(type: nil, url: f["url"], command: f["command"]),
                location: toml.path, status: f["enabled"] == "false" ? .disabled : .enabled, sharedWith: []))
        }
    }
}
