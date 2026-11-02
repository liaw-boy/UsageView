import Foundation

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunning: Sendable {
    func run(_ tool: String, _ args: [String], timeout: TimeInterval) async -> CommandResult
}

/// Runs a CLI such as `opencode` or `claude` without going through a shell (arguments are never re-parsed).
/// The executable is located once through the user's login shell, because an app launched from Finder has a minimal PATH.
public struct ShellCommandRunner: CommandRunning {
    public init() {}

    private static let cache = NSCache<NSString, NSString>()

    static func locate(_ tool: String) -> String? {
        if let hit = cache.object(forKey: tool as NSString) { return hit as String }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let path = out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") }),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        cache.setObject(path as NSString, forKey: tool as NSString)
        return path
    }

    public func run(_ tool: String, _ args: [String], timeout: TimeInterval = 90) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            guard let exe = Self.locate(tool) else {
                return CommandResult(status: 127, output: "找不到 `\(tool)` 指令，請確認已安裝並在 PATH 中。")
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return CommandResult(status: 126, output: error.localizedDescription) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            var text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 1500 { text = String(text.suffix(1500)) }
            return CommandResult(status: p.terminationStatus, output: text)
        }.value
    }
}

public enum ToolingActionError: LocalizedError, Equatable {
    case notAllowed(String)
    case invalidInput(String)
    case alreadyExists(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let m), .invalidInput(let m), .alreadyExists(let m), .failed(let m): m
        }
    }
}

/// How an item can be removed. Nil means "not removable from here" (the UI hides the button).
public enum RemovalMethod: Equatable, Sendable {
    case trash                 // moved to the macOS Trash (restorable)
    case cli(String)           // human-readable command that will run
    case editOpenCodeConfig    // delete one key from opencode.json (backup first)
}

public enum NewMCP: Sendable, Equatable {
    case remote(url: String, headers: [String: String])
    case local(command: String, env: [String: String])
}

/// The only place that changes anything on disk or runs external commands for tool management.
/// Everything is validated here, nothing is deleted permanently, and edited config files are backed up first.
public struct ToolingActions: Sendable {
    public let home: URL
    public let env: [String: String]
    public let runner: CommandRunning

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                env: [String: String] = ProcessInfo.processInfo.environment,
                runner: CommandRunning = ShellCommandRunner()) {
        self.home = home
        self.env = env
        self.runner = runner
    }

    // MARK: - Roots

    private func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

    var openCodeBase: URL {
        env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : expand($0).appendingPathComponent("opencode") }
            ?? home.appendingPathComponent(".config/opencode")
    }
    var claudeBase: URL { env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : expand($0) } ?? home.appendingPathComponent(".claude") }
    var codexBase: URL { env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : expand($0) } ?? home.appendingPathComponent(".codex") }

    /// Folders whose direct children we are willing to move to the Trash.
    var trashableRoots: [URL] {
        [openCodeBase.appendingPathComponent("skills"), openCodeBase.appendingPathComponent("agents"),
         openCodeBase.appendingPathComponent("plugins"),
         claudeBase.appendingPathComponent("skills"), claudeBase.appendingPathComponent("agents"),
         codexBase.appendingPathComponent("skills"), home.appendingPathComponent(".agents/skills")]
    }

    public func skillsRoot(for tool: ToolID) -> URL {
        switch tool {
        case .opencode: openCodeBase.appendingPathComponent("skills")
        case .claudeCode: claudeBase.appendingPathComponent("skills")
        case .codex: codexBase.appendingPathComponent("skills")
        }
    }

    // MARK: - Capabilities

    public func removalMethod(for item: ToolingItem) -> RemovalMethod? {
        switch (item.tool, item.kind) {
        case (_, .skill), (_, .agent):
            return isDirectChildOfTrashableRoot(item.location) ? .trash : nil
        case (.opencode, .plugin):
            if isDirectChildOfTrashableRoot(item.location), item.spec == nil { return .trash }
            return item.spec.map { .cli("opencode plugin remove \($0)") }
        case (.opencode, .mcp):
            return .editOpenCodeConfig
        case (.claudeCode, .mcp):
            return .cli("claude mcp remove --scope user \(item.name)")
        case (.claudeCode, .plugin):
            return .cli("claude plugin uninstall \(item.name)")
        default:
            return nil
        }
    }

    /// Claude Code plugins can be switched on/off without uninstalling.
    public func canToggle(_ item: ToolingItem) -> Bool { item.tool == .claudeCode && item.kind == .plugin }

    /// Remote OpenCode MCP servers may need OAuth.
    public func canAuthorize(_ item: ToolingItem) -> Bool {
        item.tool == .opencode && item.kind == .mcp && item.detail.hasPrefix("remote")
    }

    private func isDirectChildOfTrashableRoot(_ path: String?) -> Bool {
        guard let path else { return false }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        return trashableRoots.contains { $0.standardizedFileURL.path == parent }
    }

    // MARK: - Validation

    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 64,
              name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.@-]*$"#, options: .regularExpression) != nil
        else { throw ToolingActionError.invalidInput("名稱只能使用英數字、-、_、.、@，且不可為空（最長 64 字元）。") }
    }

    public static func validateSpec(_ spec: String) throws {
        guard !spec.isEmpty, !spec.hasPrefix("-"), spec.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, spec.count <= 300
        else { throw ToolingActionError.invalidInput("套件名稱不可為空、不可含空白、也不可以 - 開頭。") }
    }

    public static func validateURL(_ text: String) throws {
        guard let u = URL(string: text), let host = u.host, !host.isEmpty,
              u.scheme == "https" || (u.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        else { throw ToolingActionError.invalidInput("網址必須是 https://（本機測試可用 http://localhost）。") }
    }

    // MARK: - Remove

    @discardableResult
    public func remove(_ item: ToolingItem) async throws -> String {
        guard let method = removalMethod(for: item) else {
            throw ToolingActionError.notAllowed("這個項目無法從這裡移除，請手動處理。")
        }
        switch method {
        case .trash:
            guard let path = item.location else { throw ToolingActionError.notAllowed("找不到項目位置。") }
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return "已移到垃圾桶，可從垃圾桶復原。"
        case .editOpenCodeConfig:
            let file = try fileURL(item)
            try removeConfigKey(path: item.spec?.split(separator: ".").map(String.init) ?? ["mcp", "servers", item.name], in: file)
            return "已從 \(file.lastPathComponent) 移除 \(item.name)（已備份原檔，註解與排版保留）。"
        case .cli:
            switch (item.tool, item.kind) {
            case (.opencode, .plugin):
                try Self.validateSpec(item.spec ?? "")
                return try await check(runner.run("opencode", ["plugin", "remove", item.spec ?? ""], timeout: 120))
            case (.claudeCode, .mcp):
                try Self.validateName(item.name)
                return try await check(runner.run("claude", ["mcp", "remove", "--scope", "user", item.name], timeout: 60))
            case (.claudeCode, .plugin):
                try Self.validateSpec(item.name)
                return try await check(runner.run("claude", ["plugin", "uninstall", item.name], timeout: 120))
            default:
                throw ToolingActionError.notAllowed("不支援的移除方式。")
            }
        }
    }

    private func check(_ r: CommandResult) throws -> String {
        guard r.succeeded else { throw ToolingActionError.failed(r.output.isEmpty ? "指令失敗（代碼 \(r.status)）" : r.output) }
        return r.output.isEmpty ? "完成。" : r.output
    }

    func fileURL(_ item: ToolingItem) throws -> URL {
        guard let path = item.location, FileManager.default.fileExists(atPath: path) else {
            throw ToolingActionError.failed("找不到設定檔。")
        }
        // Only OpenCode's own config files may be edited, whatever the item claims as its location.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == openCodeBase.standardizedFileURL.path,
              ["opencode.json", "opencode.jsonc"].contains(url.lastPathComponent)
        else { throw ToolingActionError.notAllowed("只能編輯 OpenCode 的設定檔。") }
        return url
    }

    /// Deletes one key from an OpenCode config file. OpenCode has no `mcp remove` command and its docs say to
    /// delete the entry by hand, so the edit is surgical: comments, key order and formatting all survive.
    func removeConfigKey(path: [String], in file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let updated = try JSONCText.removingKey(path: path, in: text)
        let original = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber
        try Self.backup(file)
        try Data(updated.utf8).write(to: file, options: .atomic)
        // An atomic write replaces the inode; keep the original's (often 0600) permissions.
        if let original { try? FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: file.path) }
    }

    @discardableResult
    static func backup(_ file: URL) throws -> URL {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] // two edits within one second must not collide
        let stamp = f.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dest = file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).usageview-bak-\(stamp)")
        try FileManager.default.copyItem(at: file.resolvingSymlinksInPath(), to: dest) // copy the content, not a link
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return dest
    }

    // MARK: - Toggle / authorize

    @discardableResult
    public func setEnabled(_ item: ToolingItem, enabled: Bool) async throws -> String {
        guard canToggle(item) else { throw ToolingActionError.notAllowed("這個項目不能切換啟用狀態。") }
        try Self.validateSpec(item.name)
        return try await check(runner.run("claude", ["plugin", enabled ? "enable" : "disable", item.name], timeout: 60))
    }

    /// OAuth is interactive: the authorization link is printed by the CLI and must stay visible, so the command
    /// is handed to Terminal.app instead of being captured in a pipe (OpenCode's own docs warn about hiding it).
    @discardableResult
    public func authorize(_ item: ToolingItem, opener: (String) -> Bool = ToolingActions.openInTerminal) throws -> String {
        guard canAuthorize(item) else { throw ToolingActionError.notAllowed("這個項目不需要授權。") }
        try Self.validateName(item.name)
        guard opener("opencode mcp auth \(item.name)") else {
            throw ToolingActionError.failed("無法開啟「終端機」，請手動執行：opencode mcp auth \(item.name)")
        }
        return "已在「終端機」開始授權流程，請在那裡完成瀏覽器登入。完成後可按「重新掃描」。"
    }

    public static func openInTerminal(_ command: String) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Add

    /// Copies a local skill folder (must contain SKILL.md) into the tool's skills folder. Never overwrites.
    @discardableResult
    public func installSkill(from source: URL, for tool: ToolID) throws -> String {
        let name = source.lastPathComponent
        try Self.validateName(name)
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw ToolingActionError.invalidInput("所選資料夾裡沒有 SKILL.md，不是有效的 skill。")
        }
        let root = skillsRoot(for: tool)
        let dest = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw ToolingActionError.alreadyExists("\(tool.displayName) 已經有同名的 skill「\(name)」，不會覆蓋。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dest)
        return "已安裝到 \((dest.path as NSString).abbreviatingWithTildeInPath)"
    }

    @discardableResult
    public func addPlugin(_ spec: String, for tool: ToolID) async throws -> String {
        let spec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateSpec(spec)
        switch tool {
        case .opencode: return try await check(runner.run("opencode", ["plugin", "add", spec], timeout: 180))
        case .claudeCode: return try await check(runner.run("claude", ["plugin", "install", spec], timeout: 180))
        case .codex: throw ToolingActionError.notAllowed("Codex 暫不支援從這裡新增 plugin。")
        }
    }

    @discardableResult
    /// Neither `opencode mcp add` nor `claude mcp add` accepts secrets on stdin or through the environment, so
    /// header and env values travel as command-line arguments and are visible in the process list while the CLI runs.
    /// The UI says so; keep this in mind before adding any new secret-carrying argument.
    public func addMCP(name: String, spec: NewMCP, for tool: ToolID) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateName(name)
        switch (tool, spec) {
        case (.opencode, .remote(let url, let headers)):
            try Self.validateURL(url)
            var args = ["mcp", "add", "--global", "--url", url]
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) { args += ["--header", "\(k)=\(v)"] }
            return try await check(runner.run("opencode", args + [name], timeout: 60))
        case (.opencode, .local(let command, let env)):
            let parts = try Self.splitCommand(command)
            var args = ["mcp", "add", "--global"]
            for (k, v) in env.sorted(by: { $0.key < $1.key }) { args += ["--env", "\(k)=\(v)"] }
            return try await check(runner.run("opencode", args + [name, "--"] + parts, timeout: 60))
        case (.claudeCode, .remote(let url, let headers)):
            try Self.validateURL(url)
            var args = ["mcp", "add", "--scope", "user", "--transport", "http"]
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) { args += ["-H", "\(k): \(v)"] }
            return try await check(runner.run("claude", args + [name, url], timeout: 60))
        case (.claudeCode, .local(let command, let env)):
            let parts = try Self.splitCommand(command)
            var args = ["mcp", "add", "--scope", "user", "--transport", "stdio"]
            for (k, v) in env.sorted(by: { $0.key < $1.key }) { args += ["-e", "\(k)=\(v)"] }
            return try await check(runner.run("claude", args + [name, "--"] + parts, timeout: 60))
        case (.codex, _):
            throw ToolingActionError.notAllowed("Codex 暫不支援從這裡新增 MCP。")
        }
    }

    public static func splitCommand(_ text: String) throws -> [String] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, !first.hasPrefix("-") else {
            throw ToolingActionError.invalidInput("請輸入要執行的指令，例如 npx -y some-mcp-server。")
        }
        return parts
    }
}
