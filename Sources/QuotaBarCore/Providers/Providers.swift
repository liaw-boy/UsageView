import Foundation

/// One provider = AuthStore (read credentials) + UsageClient (HTTP) + Mapper (normalize).
public protocol ProviderRuntime: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> [MetricLine]
}

public enum ProviderCatalog {
    public static func all(http: HTTPClient = HTTPClient(),
                           credentials: CredentialSource = SystemCredentialSource()) -> [ProviderRuntime] {
        [
            ClaudeRuntime(http: http, credentials: credentials),
            CodexRuntime(http: http, credentials: credentials),
            AntigravityRuntime(http: http, credentials: credentials),
        ]
    }
}

// MARK: - Claude

/// Credentials: Keychain "Claude Code-credentials" or ~/.claude/.credentials.json (written by Claude Code).
/// Never refreshes or writes tokens so the user's CLI login is never disturbed.
struct ClaudeAuthStore: Sendable {
    let credentials: CredentialSource

    func accessToken() -> String? {
        let base = credentials.env("CLAUDE_CONFIG_DIR") ?? "~/.claude"
        let raw = Parse.object(credentials.keychain(service: "Claude Code-credentials", account: nil))
            ?? Parse.object(credentials.file(base + "/.credentials.json"))
        return (raw?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    }
}

enum ClaudeMapper {
    static let windows: [(key: String, label: String, kind: WindowKind)] = [
        ("five_hour", "5 小時", .session),
        ("seven_day", "每週", .weekly),
        ("seven_day_opus", "每週 · Opus", .weekly),
        ("seven_day_sonnet", "每週 · Sonnet", .weekly),
    ]

    static func map(_ body: [String: Any]) throws -> [MetricLine] {
        let lines = windows.compactMap { spec -> MetricLine? in
            guard let w = body[spec.key] as? [String: Any], let used = Parse.number(w["utilization"]) else { return nil }
            return MetricLine(id: spec.key, label: spec.label, kind: spec.kind,
                              usedPercent: used, resetsAt: Parse.date(w["resets_at"]))
        }
        guard !lines.isEmpty else { throw ProviderError.parse }
        return lines
    }
}

struct ClaudeRuntime: ProviderRuntime {
    let id = ProviderID.claude
    let http: HTTPClient
    let credentials: CredentialSource

    func fetch() async throws -> [MetricLine] {
        guard let token = ClaudeAuthStore(credentials: credentials).accessToken() else {
            throw ProviderError.notLoggedIn("找不到 Claude Code 登入，請先執行 claude")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let r = try await http.send(req)
        try ProviderError.check(r, unauthorizedHint: "Token 已過期，執行一次 claude 即可自動更新")
        return try ClaudeMapper.map(r.json)
    }
}

// MARK: - Codex

/// Credentials: $CODEX_HOME/auth.json (default ~/.codex). Never refreshed or written.
struct CodexAuthStore: Sendable {
    let credentials: CredentialSource

    func tokens() -> (access: String, account: String?)? {
        let home = credentials.env("CODEX_HOME") ?? "~/.codex"
        guard let auth = Parse.object(credentials.file(home + "/auth.json")),
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else { return nil }
        return (access, tokens["account_id"] as? String)
    }
}

enum CodexMapper {
    static func map(_ body: [String: Any]) throws -> [MetricLine] {
        guard let rl = body["rate_limit"] as? [String: Any] else { throw ProviderError.parse }
        let slots: [(key: String, fallback: WindowKind)] = [("primary_window", .session), ("secondary_window", .weekly)]
        let lines = slots.compactMap { slot -> MetricLine? in
            guard let w = rl[slot.key] as? [String: Any], let used = Parse.number(w["used_percent"]) else { return nil }
            // Classify by duration, not slot (Codex sometimes moves weekly into primary).
            let seconds = Parse.number(w["limit_window_seconds"])
            let kind: WindowKind = seconds.map { $0 <= 6 * 3600 ? .session : .weekly } ?? slot.fallback
            let reset = Parse.number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            return MetricLine(id: kind.rawValue, label: kind == .session ? "5 小時" : "每週", kind: kind,
                              usedPercent: used, resetsAt: reset, periodSeconds: seconds)
        }
        guard !lines.isEmpty else { throw ProviderError.parse }
        return lines.sorted { $0.kind == .session && $1.kind == .weekly }
    }
}

struct CodexRuntime: ProviderRuntime {
    let id = ProviderID.codex
    let http: HTTPClient
    let credentials: CredentialSource

    func fetch() async throws -> [MetricLine] {
        guard let t = CodexAuthStore(credentials: credentials).tokens() else {
            throw ProviderError.notLoggedIn("找不到 Codex 登入，請先執行 codex login")
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(t.access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account = t.account { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let r = try await http.send(req)
        try ProviderError.check(r, unauthorizedHint: "Token 已過期，執行一次 codex 即可自動更新")
        return try CodexMapper.map(r.json)
    }
}

// MARK: - Antigravity

/// Credentials: Keychain service "gemini", account "antigravity" (go-keyring-base64 JSON), written by Antigravity / agy.
/// Read-only; no OAuth client ID or secret is embedded in the repository.
struct AntigravityAuthStore: Sendable {
    let credentials: CredentialSource

    func accessToken() -> String? {
        guard var text = credentials.keychain(service: "gemini", account: "antigravity") else { return nil }
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let d = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { return nil }
            text = String(decoding: d, as: UTF8.self)
        }
        guard let root = Parse.object(text) else { return nil }
        let src = root["token"] as? [String: Any] ?? root
        let access = (src["access_token"] ?? src["accessToken"]) as? String
        return (access?.isEmpty == false) ? access : nil
    }
}

enum AntigravityMapper {
    static let buckets: [(id: String, label: String, kind: WindowKind, pool: String)] = [
        ("gemini-5h", "Gemini · 5 小時", .session, "gemini"),
        ("gemini-weekly", "Gemini · 每週", .weekly, "gemini"),
        ("3p-5h", "Claude/GPT · 5 小時", .session, "3p"),
        ("3p-weekly", "Claude/GPT · 每週", .weekly, "3p"),
    ]

    /// Merge summary bodies by exact bucket id; first usable bucket wins.
    static func map(_ bodies: [[String: Any]]) -> [MetricLine] {
        var found: [String: MetricLine] = [:]
        for body in bodies {
            let groups = (body["groups"] ?? (body["response"] as? [String: Any])?["groups"]) as? [[String: Any]] ?? []
            for bucket in groups.flatMap({ $0["buckets"] as? [[String: Any]] ?? [] }) {
                guard let id = bucket["bucketId"] as? String, found[id] == nil,
                      let spec = buckets.first(where: { $0.id == id }),
                      let remaining = Parse.number(bucket["remainingFraction"]), remaining.isFinite
                else { continue }
                found[id] = MetricLine(id: id, label: spec.label, kind: spec.kind, pool: spec.pool,
                                       usedPercent: (1 - remaining) * 100, resetsAt: Parse.date(bucket["resetTime"]))
            }
        }
        return buckets.compactMap { found[$0.id] }
    }
}

struct AntigravityRuntime: ProviderRuntime {
    let id = ProviderID.antigravity
    let http: HTTPClient
    let credentials: CredentialSource

    static let hosts = ["https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com"]
    static let userAgent = "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=arm64)"

    func fetch() async throws -> [MetricLine] {
        guard let token = AntigravityAuthStore(credentials: credentials).accessToken() else {
            throw ProviderError.notLoggedIn("找不到 Antigravity 登入，請開啟 Antigravity 或執行 agy")
        }

        var bodies: [[String: Any]] = []
        var lastError: ProviderError = .parse
        for host in Self.hosts {
            let r = try await summary(host: host, token: token)
            do {
                try ProviderError.check(r, unauthorizedHint: "Token 已過期，請開啟 Antigravity 或執行 agy 自動更新")
                bodies.append(r.json)
                if AntigravityMapper.map(bodies).count == AntigravityMapper.buckets.count { break }
            } catch let e as ProviderError {
                lastError = e
            }
        }
        let lines = AntigravityMapper.map(bodies)
        if lines.isEmpty { throw lastError }
        return lines
    }

    private func summary(host: String, token: String) async throws -> HTTPResult {
        var req = URLRequest(url: URL(string: host + "/v1internal:retrieveUserQuotaSummary")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = Data("{}".utf8)
        return try await http.send(req)
    }
}
