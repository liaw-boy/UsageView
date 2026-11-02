import Foundation

/// Claude Code hands its `statusLine` command the account's rate limits after every reply. This bridge installs a
/// generic wrapper as that command so UsageView can read them from a local file instead of polling the rate-limited
/// usage API. A status line the user already had keeps running behind the wrapper with the same input.
/// Everything stays inside the user's Claude config folder; nothing user-specific is bundled with the app.
public struct ClaudeStatusLineBridge: Sendable {
    public static let command = "sh ~/.claude/usageview-statusline.sh"
    public static let limitsFileName = "usageview-rate-limits.json"

    static let script = """
    #!/bin/sh
    # Installed by UsageView. Saves the rate limits Claude Code passes to the status line so UsageView can read
    # them without calling the usage API, then runs the status line you had before (if any) with the same input.
    # Turn off "從 Claude Code 狀態列讀取額度" in UsageView settings to restore your previous status line.
    dir=$(dirname "$0")
    input=$(cat)
    # Keep only rate_limits (not cwd, transcript path, ...); plutil ships with macOS, unlike jq.
    limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
    if [ -n "$limits" ]; then
      (
        umask 077
        tmp="$dir/usageview-rate-limits.json.$$"
        printf '{"written_at":%s,"rate_limits":%s}' "$(date +%s)" "$limits" > "$tmp" && mv -f "$tmp" "$dir/usageview-rate-limits.json"
      )
    fi
    if [ -s "$dir/usageview-statusline.next" ]; then
      printf '%s' "$input" | sh -c "$(cat "$dir/usageview-statusline.next")"
    fi
    exit 0

    """

    public enum BridgeError: LocalizedError {
        case unreadableSettings
        public var errorDescription: String? { "無法解析 Claude Code 的 settings.json，未做任何修改" }
    }

    let claudeDir: URL

    public init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    /// Resolved so a dotfiles symlink stays a symlink and its target is what gets backed up and edited.
    var settingsURL: URL { claudeDir.appendingPathComponent("settings.json").resolvingSymlinksInPath() }
    var scriptURL: URL { claudeDir.appendingPathComponent("usageview-statusline.sh") }
    /// The previous status line command, run by the wrapper.
    var nextURL: URL { claudeDir.appendingPathComponent("usageview-statusline.next") }
    /// The previous `statusLine` value, restored verbatim on uninstall.
    var originalURL: URL { claudeDir.appendingPathComponent("usageview-statusline-original.json") }
    public var limitsURL: URL { claudeDir.appendingPathComponent(Self.limitsFileName) }

    static func isOurs(_ statusLine: Any?) -> Bool {
        ((statusLine as? [String: Any])?["command"] as? String)?.contains("usageview-statusline.sh") == true
    }

    /// Claude Code has appeared since launch and the bridge was never set up (cheap: two stat calls). False after the
    /// user switched to another status line, which `install()` would leave alone anyway.
    public var needsInstall: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: claudeDir.path) && !fm.fileExists(atPath: scriptURL.path)
            && !fm.fileExists(atPath: originalURL.path)
    }

    /// Installs (or refreshes) the wrapper. Does nothing when Claude Code has never run on this Mac, and never
    /// re-wraps a status line the user switched to after we installed (turning the setting off and on again does).
    public func install() throws {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return }
        var settings = try readSettings()
        let current = settings["statusLine"]
        if !Self.isOurs(current), FileManager.default.fileExists(atPath: originalURL.path) { return }
        try write(Data(Self.script.utf8), to: scriptURL)
        if Self.isOurs(current) { return }

        let original: [String: Any] = current.map { ["statusLine": $0] } ?? [:]
        try write(JSONSerialization.data(withJSONObject: original), to: originalURL)
        if let cmd = (current as? [String: Any])?["command"] as? String, !cmd.isEmpty {
            try write(Data(cmd.utf8), to: nextURL)
        } else {
            try? FileManager.default.removeItem(at: nextURL)
        }
        var line = (current as? [String: Any]) ?? [:] // keep options such as padding
        line["type"] = "command"
        line["command"] = Self.command
        settings["statusLine"] = line
        try saveSettings(settings)
    }

    /// Restores the previous status line (only if ours is still the active one) and removes the bridge's files.
    public func uninstall() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scriptURL.path) || fm.fileExists(atPath: originalURL.path) else { return }
        var settings = try readSettings()
        if Self.isOurs(settings["statusLine"]) {
            let saved = Parse.object(try? Data(contentsOf: originalURL))
            let next = (try? String(contentsOf: nextURL, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
            settings["statusLine"] = saved?["statusLine"] ?? next.map { ["type": "command", "command": $0] }
            try saveSettings(settings)
        }
        for url in [scriptURL, nextURL, originalURL, limitsURL] { try? fm.removeItem(at: url) }
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let obj = Parse.object(try Data(contentsOf: settingsURL)) else { throw BridgeError.unreadableSettings }
        return obj
    }

    private func saveSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let original = (try? FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions]) as? NSNumber
        if FileManager.default.fileExists(atPath: settingsURL.path) { try ToolingActions.backup(settingsURL) }
        try data.write(to: settingsURL, options: .atomic)
        if let original { try? FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: settingsURL.path) }
    }

    /// Created 0600 from the start (the saved command may carry a token), then renamed into place.
    private func write(_ data: Data, to url: URL) throws {
        let tmp = url.path + ".tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, url.path) == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
