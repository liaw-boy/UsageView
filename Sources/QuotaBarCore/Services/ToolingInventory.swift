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
    public var id: String { "\(tool.rawValue)|\(kind.rawValue)|\(name)|\(location ?? "")|\(source ?? "")|\(spec ?? "")" }
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
    /// Where a read-only item comes from (a project, a plugin, claude.ai sync). Non-nil means: list only, never act on it.
    public var source: String? = nil
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

    /// Project folders under privacy-protected or removable locations would trigger a TCC prompt or hang on a dead mount.
    static func isSafeToRead(projectPath: String, home: URL) -> Bool {
        // Resolve symlinks first: `~/code` pointing into `~/Documents` must still count as protected.
        // APFS is case-insensitive by default, so compare case-insensitively too.
        let path = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard path.hasPrefix(homePath + "/") else { return false }
        let protected = ["desktop", "documents", "downloads", "library"]
        return !protected.contains { path == homePath + "/" + $0 || path.hasPrefix(homePath + "/" + $0 + "/") }
    }

    /// `spec` carries the full project path so two projects with the same folder name stay distinct.
    private static func appendMCP(_ servers: [String: Any], location: String, source: String?, spec: String? = nil,
                                  status: (String) -> ToolingStatus, into inv: inout ToolingInventory) {
        for (name, value) in servers {
            guard let m = value as? [String: Any] else { continue }
            var item = ToolingItem(
                tool: .claudeCode, kind: .mcp, name: name,
                detail: mcpDetail(type: m["type"] as? String, url: m["url"] as? String, command: m["command"] as? String),
                location: location, status: status(name), sharedWith: [])
            item.source = source
            item.spec = spec
            inv.items.append(item)
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

        let userCfg = json(userJSON, warnings: &inv.warnings)
        if let cfg = userCfg {
            appendMCP(cfg["mcpServers"] as? [String: Any] ?? [:], location: userJSON.path, source: nil,
                      status: { _ in .enabled }, into: &inv)
        }

        // Project-scoped MCP: per-project entries in ~/.claude.json and each project's shared `.mcp.json`. Read-only.
        if let projects = userCfg?["projects"] as? [String: Any] {
            for (path, value) in projects {
                let source = "專案 · \((path as NSString).lastPathComponent)"
                let proj = value as? [String: Any] ?? [:]
                let disabledLocal = Set(proj["disabledMcpServers"] as? [String] ?? [])
                appendMCP(proj["mcpServers"] as? [String: Any] ?? [:], location: userJSON.path, source: source, spec: path,
                          status: { disabledLocal.contains($0) ? .disabled : .enabled }, into: &inv)
                guard isSafeToRead(projectPath: path, home: home) else { continue }
                let shared = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
                if let cfg = json(shared, warnings: &inv.warnings) {
                    // `.mcp.json` servers need the user's approval in Claude Code; unanswered ones are neither on nor off.
                    let approved = Set(proj["enabledMcpjsonServers"] as? [String] ?? [])
                    let rejected = Set(proj["disabledMcpjsonServers"] as? [String] ?? [])
                    let all = proj["enableAllProjectMcpServers"] as? Bool ?? false
                    appendMCP(cfg["mcpServers"] as? [String: Any] ?? [:], location: shared.path, source: source, spec: path,
                              status: { rejected.contains($0) ? .disabled : (all || approved.contains($0)) ? .enabled : .unknown },
                              into: &inv)
                }
            }
        }

        // Skills synced from claude.ai live one level deeper (skills/synced/<bucket>/<skill>); buckets can repeat a skill.
        var syncedNames = Set<String>()
        let syncedRoot = base.appendingPathComponent("skills/synced")
        let buckets = (try? FileManager.default.contentsOfDirectory(at: syncedRoot, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        for bucket in buckets.sorted(by: { $0.path < $1.path }) {
            for s in skills(in: bucket) where syncedNames.insert(s.name).inserted {
                var item = ToolingItem(tool: .claudeCode, kind: .skill, name: s.name, detail: s.description,
                                       location: s.path, status: .enabled, sharedWith: [])
                item.source = "claude.ai 同步"
                inv.items.append(item)
            }
        }

        // Plugins: enabled flag from settings.json, version + install folder from installed_plugins.json
        var versions: [String: String] = [:]
        var installPaths: [String: URL] = [:]
        let pluginsRoot = base.appendingPathComponent("plugins").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        if let installed = json(base.appendingPathComponent("plugins/installed_plugins.json"), warnings: &inv.warnings),
           let plugins = installed["plugins"] as? [String: [[String: Any]]] {
            for (name, entries) in plugins {
                if let v = entries.first?["version"] as? String { versions[name] = v }
                // Only follow install paths inside Claude's own plugins folder; the JSON is not a trust boundary we own.
                if let p = entries.first?["installPath"] as? String {
                    let url = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL
                    if url.path.hasPrefix(pluginsRoot) { installPaths[name] = url }
                }
            }
        }
        let enabledPlugins = (json(base.appendingPathComponent("settings.json"), warnings: &inv.warnings)?["enabledPlugins"]
                              as? [String: Bool]) ?? [:]
        for (name, folder) in installPaths {
            let source = "Plugin · \(name.split(separator: "@").first.map(String.init) ?? name)"
            let status: ToolingStatus = enabledPlugins[name].map { $0 ? .enabled : .disabled } ?? .unknown
            for s in skills(in: folder.appendingPathComponent("skills")) {
                var item = ToolingItem(tool: .claudeCode, kind: .skill, name: s.name, detail: s.description,
                                       location: s.path, status: status, sharedWith: [])
                item.source = source
                inv.items.append(item)
            }
            for a in markdownAgents(in: folder.appendingPathComponent("agents")) {
                var item = ToolingItem(tool: .claudeCode, kind: .agent, name: a.name, detail: a.description,
                                       location: a.path, status: status, sharedWith: [])
                item.source = source
                inv.items.append(item)
            }
            let mcpFile = folder.appendingPathComponent(".mcp.json")
            if let cfg = json(mcpFile, warnings: &inv.warnings) {
                // Plugin `.mcp.json` comes both wrapped in `mcpServers` and as a bare name → server map.
                appendMCP(cfg["mcpServers"] as? [String: Any] ?? cfg, location: mcpFile.path, source: source,
                          status: { _ in status }, into: &inv)
            }
        }
        for (name, on) in enabledPlugins {
            inv.items.append(ToolingItem(tool: .claudeCode, kind: .plugin, name: name,
                                         detail: versions[name].map { "v\($0)" } ?? "",
                                         location: base.appendingPathComponent("settings.json").path,
                                         status: on ? .enabled : .disabled, sharedWith: []))
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
