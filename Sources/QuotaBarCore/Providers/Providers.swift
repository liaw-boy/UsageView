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
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-cli/2.1.294 (external, cli)", forHTTPHeaderField: "User-Agent")
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
/// No OAuth client ID or secret is hardcoded in source code; if the access token expires, the installed-app OAuth
/// client parameters are discovered dynamically from the local `agy` / `Antigravity` binary on disk and cached in memory.
struct AntigravityAuthStore: Sendable {
    let credentials: CredentialSource

    struct Token {
        var access: String?
        var refresh: String?
        var expiry: Date?
    }

    func load() -> Token? {
        guard var text = credentials.keychain(service: "gemini", account: "antigravity") else { return nil }
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let d = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { return nil }
            text = String(decoding: d, as: UTF8.self)
        }
        guard let root = Parse.object(text) else { return nil }
        let src = root["token"] as? [String: Any] ?? root
        let token = Token(
            access: (src["access_token"] ?? src["accessToken"]) as? String,
            refresh: (src["refresh_token"] ?? src["refreshToken"]) as? String,
            expiry: Parse.date(src["expiry"] ?? src["expires_at"] ?? src["expiresAt"])
        )
        return token.access == nil && token.refresh == nil ? nil : token
    }

    /// Reads the public installed-app OAuth client ID & secret from the locally installed `agy` binary at runtime,
    /// so zero secrets or client IDs are ever stored in this repository.
    static let localOAuthClient: (id: String, secret: String)? = {
        let candidates = [
            "~/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
        ]
        for path in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded), options: .mappedIfSafe) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard let idRange = text.range(of: #"1071[0-9]+-[a-z0-9]{32}\.apps\.googleusercontent\.com"#, options: .regularExpression),
                  let secretRange = text.range(of: #"GOCSPX-[A-Za-z0-9_-]{28}"#, options: .regularExpression)
            else { continue }
            return (String(text[idRange]), String(text[secretRange]))
        }
        return nil
    }()
}

/// Thread-safe in-memory cache for Antigravity's refreshed access token so we don't refresh on every cycle.
private final class InMemoryTokenCache: @unchecked Sendable {
    static let shared = InMemoryTokenCache()
    private let lock = NSLock()
    private var access: String?
    private var expiry: Date?

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let access, let expiry, expiry.timeIntervalSinceNow > 60 else { return nil }
        return access
    }

    func set(_ token: String, expiresIn: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        access = token
        expiry = Date().addingTimeInterval(max(expiresIn, 300))
    }
}

enum AntigravityMapper {
    static let argonGroupName = "Gemini 4 Argon"
    static let buckets: [(id: String, label: String, kind: WindowKind, pool: String)] = [
        ("gemini-5h", "Gemini · 5 小時", .session, "gemini"),
        ("gemini-weekly", "Gemini · 每週", .weekly, "gemini"),
        ("3p-5h", "Claude/GPT · 5 小時", .session, "3p"),
        ("3p-weekly", "Claude/GPT · 每週", .weekly, "3p"),
    ]

    /// Merges summary bodies across both Cloud Code hosts (`daily-cloudcode-pa` and `cloudcode-pa`):
    /// - `agy` CLI deducts Gemini (including Gemini 4 Argon on Ultra) on `daily-cloudcode-pa`, while
    ///   `cloudcode-pa` may report `remainingFraction: 1.0` (untouched). Therefore, when both hosts report
    ///   the same bucket ID, we keep the one with higher usage (`usedPercent`) so active usage on either
    ///   host is never masked by an untouched `1.0` on the other host.
    /// - If the account has a separate `"Gemini 4 Argon"` group (Pro / trial accounts), it is surfaced as
    ///   its own `Gemini 4 Argon · 每週` meter. On Ultra accounts, Gemini 4 Argon shares the `gemini-5h`
    ///   and `gemini-weekly` pool.
    static func map(_ bodies: [[String: Any]]) -> [MetricLine] {
        var found: [String: MetricLine] = [:]
        var argonLine: MetricLine?

        for body in bodies {
            let groups = (body["groups"] ?? (body["response"] as? [String: Any])?["groups"]) as? [[String: Any]] ?? []
            for group in groups {
                let groupName = group["displayName"] as? String
                let groupBuckets = group["buckets"] as? [[String: Any]] ?? []

                if groupName == argonGroupName {
                    if argonLine == nil,
                       let weekly = groupBuckets.first(where: { ($0["window"] as? String) == "weekly" && ($0["disabled"] as? Bool) != true }),
                       let remaining = Parse.number(weekly["remainingFraction"]), remaining.isFinite {
                        argonLine = MetricLine(
                            id: "argon-weekly",
                            label: "Gemini 4 Argon · 每週",
                            kind: .weekly,
                            pool: "gemini",
                            usedPercent: (1 - remaining) * 100,
                            resetsAt: Parse.date(weekly["resetTime"])
                        )
                    }
                    continue
                }

                for bucket in groupBuckets {
                    guard let id = bucket["bucketId"] as? String,
                          let spec = buckets.first(where: { $0.id == id }),
                          let remaining = Parse.number(bucket["remainingFraction"]), remaining.isFinite
                    else { continue }
                    let used = (1 - remaining) * 100
                    let candidate = MetricLine(
                        id: id,
                        label: spec.label,
                        kind: spec.kind,
                        pool: spec.pool,
                        usedPercent: used,
                        resetsAt: Parse.date(bucket["resetTime"])
                    )
                    if let existing = found[id] {
                        if candidate.usedPercent > existing.usedPercent {
                            found[id] = candidate
                        }
                    } else {
                        found[id] = candidate
                    }
                }
            }
        }

        var lines = buckets.compactMap { found[$0.id] }
        if let argonLine {
            let insertIdx = lines.firstIndex(where: { $0.pool == "3p" }) ?? lines.endIndex
            lines.insert(argonLine, at: insertIdx)
        }
        return lines
    }
}

struct AntigravityRuntime: ProviderRuntime {
    let id = ProviderID.antigravity
    let http: HTTPClient
    let credentials: CredentialSource

    // Query both daily-cloudcode-pa (used by agy CLI) and cloudcode-pa (used by Antigravity IDE)
    // and merge by keeping the active (most-used) fraction for each bucket.
    static let hosts = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]
    static let userAgent = "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=arm64)"

    func fetch() async throws -> [MetricLine] {
        guard let stored = AntigravityAuthStore(credentials: credentials).load() else {
            throw ProviderError.notLoggedIn("找不到 Antigravity 登入，請開啟 Antigravity 或執行 agy")
        }

        var token: String?
        if let cached = InMemoryTokenCache.shared.get() {
            token = cached
        } else if let access = stored.access, (stored.expiry?.timeIntervalSinceNow ?? 120) > 60 {
            token = access
        } else if let refreshTok = stored.refresh {
            token = try await refreshAccessToken(refreshTok)
        } else {
            token = stored.access
        }
        guard var activeToken = token else {
            throw ProviderError.notLoggedIn("找不到 Antigravity token")
        }

        var bodies: [[String: Any]] = []
        var lastError: ProviderError = .parse
        var refreshedOnce = false
        for host in Self.hosts {
            var r = try await summary(host: host, token: activeToken)
            if (r.status == 401 || r.status == 403), !refreshedOnce, let rt = stored.refresh {
                activeToken = try await refreshAccessToken(rt)
                refreshedOnce = true
                r = try await summary(host: host, token: activeToken)
            }
            do {
                try ProviderError.check(r, unauthorizedHint: "Token 已過期，請開啟 Antigravity 或執行 agy 自動更新")
                bodies.append(r.json)
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

    private func refreshAccessToken(_ refreshToken: String) async throws -> String {
        guard let client = AntigravityAuthStore.localOAuthClient else {
            throw ProviderError.unauthorized("Token 已過期，請開啟 Antigravity 或執行 agy")
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "client_secret", value: client.secret),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "grant_type", value: "refresh_token"),
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let r = try await http.send(req)
        guard r.status == 200, let access = r.json["access_token"] as? String else {
            throw ProviderError.unauthorized("Antigravity 登入已過期，請重新登入")
        }
        let expiresIn = Parse.number(r.json["expires_in"]) ?? 3500
        InMemoryTokenCache.shared.set(access, expiresIn: expiresIn)
        return access
    }
}
