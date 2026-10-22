import Foundation

public struct ProviderFetchResult: Sendable {
    public let lines: [MetricLine]
    public let planName: String?
    public let extraUsageText: String?

    public init(lines: [MetricLine], planName: String? = nil, extraUsageText: String? = nil) {
        self.lines = lines
        self.planName = planName
        self.extraUsageText = extraUsageText
    }
}

/// One provider = AuthStore (read credentials) + UsageClient (HTTP) + Mapper (normalize).
public protocol ProviderRuntime: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> [MetricLine]
    func fetchResult() async throws -> ProviderFetchResult
}

public extension ProviderRuntime {
    func fetchResult() async throws -> ProviderFetchResult {
        ProviderFetchResult(lines: try await fetch())
    }
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
        credentialsInfo()?.accessToken
    }

    func credentialsInfo() -> (accessToken: String, planName: String?)? {
        let base = credentials.env("CLAUDE_CONFIG_DIR") ?? "~/.claude"
        let raw = Parse.object(credentials.keychain(service: "Claude Code-credentials", account: nil))
            ?? Parse.object(credentials.file(base + "/.credentials.json"))
        guard let oauth = raw?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let subType = oauth["subscriptionType"] as? String
        let tier = oauth["rateLimitTier"] as? String
        let plan = ClaudeMapper.formatPlan(subscriptionType: subType, rateLimitTier: tier)
        return (token, plan)
    }
}

enum ClaudeMapper {
    static let windows: [(key: String, label: String, kind: WindowKind)] = [
        ("five_hour", "5H", .session),
        ("seven_day", "7D", .weekly),
        ("seven_day_opus", "Opus · 7D", .weekly),
        ("seven_day_sonnet", "Sonnet · 7D", .weekly),
    ]

    static func map(_ body: [String: Any]) throws -> [MetricLine] {
        var lines = windows.compactMap { spec -> MetricLine? in
            guard let w = body[spec.key] as? [String: Any], let used = Parse.number(w["utilization"]) else { return nil }
            return MetricLine(id: spec.key, label: spec.label, kind: spec.kind,
                              usedPercent: used, resetsAt: Parse.date(w["resets_at"]))
        }
        // Scoped weekly model limits (e.g., Fable)
        if let limits = body["limits"] as? [[String: Any]] {
            for entry in limits where entry["kind"] as? String == "weekly_scoped" {
                guard let scope = entry["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let displayName = model["display_name"] as? String, !displayName.isEmpty,
                      let used = Parse.number(entry["percent"])
                else { continue }
                lines.append(MetricLine(
                    id: "weekly_\(displayName.lowercased())",
                    label: "\(displayName) · 7D",
                    kind: .weekly,
                    usedPercent: used,
                    resetsAt: Parse.date(entry["resets_at"])
                ))
            }
        }
        guard !lines.isEmpty else { throw ProviderError.parse }
        return lines
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let base = raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
        if let tier = rateLimitTier, let match = tier.range(of: #"\d+x"#, options: .regularExpression) {
            return "\(base) \(tier[match])"
        }
        return base
    }

    static func formatExtraUsage(_ body: [String: Any]) -> String? {
        guard let extra = body["extra_usage"] as? [String: Any],
              extra["is_enabled"] as? Bool == true,
              let usedCents = Parse.number(extra["used_credits"])
        else { return nil }
        let usedUSD = usedCents / 100.0
        if let limitCents = Parse.number(extra["monthly_limit"]), limitCents > 0 {
            let limitUSD = limitCents / 100.0
            return String(format: "額外用量 $%.2f / $%.0f", usedUSD, limitUSD)
        } else if usedUSD > 0 {
            return String(format: "額外用量 $%.2f", usedUSD)
        }
        return nil
    }
}

struct ClaudeRuntime: ProviderRuntime {
    let id = ProviderID.claude
    let http: HTTPClient
    let credentials: CredentialSource

    func fetch() async throws -> [MetricLine] {
        try await fetchResult().lines
    }

    func fetchResult() async throws -> ProviderFetchResult {
        guard let info = ClaudeAuthStore(credentials: credentials).credentialsInfo() else {
            throw ProviderError.notLoggedIn("找不到 Claude Code 登入，請先執行 claude")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(info.accessToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-cli/2.1.294 (external, cli)", forHTTPHeaderField: "User-Agent")
        let r = try await http.send(req)
        try ProviderError.check(r, unauthorizedHint: "Token 已過期，執行一次 claude 即可自動更新")
        let lines = try ClaudeMapper.map(r.json)
        let extra = ClaudeMapper.formatExtraUsage(r.json)
        return ProviderFetchResult(lines: lines, planName: info.planName, extraUsageText: extra)
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
        var lines = slots.compactMap { slot -> MetricLine? in
            guard let w = rl[slot.key] as? [String: Any], let used = Parse.number(w["used_percent"]) else { return nil }
            // Classify by duration, not slot (Codex sometimes moves weekly into primary).
            let seconds = Parse.number(w["limit_window_seconds"])
            let kind: WindowKind = seconds.map { $0 <= 6 * 3600 ? .session : .weekly } ?? slot.fallback
            let reset = Parse.number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            return MetricLine(id: kind.rawValue, label: kind == .session ? "5H" : "7D", kind: kind,
                              usedPercent: used, resetsAt: reset, periodSeconds: seconds)
        }
        guard !lines.isEmpty else { throw ProviderError.parse }
        lines.sort { $0.kind == .session && $1.kind == .weekly }

        // Optional Spark model-specific limits when present in `additional_rate_limits`
        if let extras = body["additional_rate_limits"] as? [[String: Any]],
           let spark = extras.first(where: {
               (($0["limit_name"] as? String) ?? ($0["metered_feature"] as? String) ?? "")
                   .lowercased().contains("spark")
           }),
           let sparkRL = spark["rate_limit"] as? [String: Any] {
            for slot in slots {
                guard let w = sparkRL[slot.key] as? [String: Any],
                      let used = Parse.number(w["used_percent"]) else { continue }
                let seconds = Parse.number(w["limit_window_seconds"])
                let kind: WindowKind = seconds.map { $0 <= 6 * 3600 ? .session : .weekly } ?? slot.fallback
                let reset = Parse.number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                lines.append(MetricLine(
                    id: "spark-\(kind.rawValue)",
                    label: kind == .session ? "Spark · 5H" : "Spark · 7D",
                    kind: kind,
                    usedPercent: used,
                    resetsAt: reset,
                    periodSeconds: seconds
                ))
            }
        }
        return lines
    }

    static func formatPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "team": return "Team"
        case "self_serve_business_prolite": return "Business"
        default:
            return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
    }

    static func formatCredits(_ body: [String: Any]) -> String? {
        guard let creditsObj = body["credits"] as? [String: Any],
              let balance = Parse.number(creditsObj["balance"]), balance > 0
        else { return nil }
        let credits = max(0, Int(balance.rounded(.down)))
        guard credits > 0 else { return nil }
        let usd = Double(credits) * 0.04
        return String(format: "點數餘額 $%.2f · %d 點", usd, credits)
    }
}

struct CodexRuntime: ProviderRuntime {
    let id = ProviderID.codex
    let http: HTTPClient
    let credentials: CredentialSource

    func fetch() async throws -> [MetricLine] {
        try await fetchResult().lines
    }

    func fetchResult() async throws -> ProviderFetchResult {
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
        let lines = try CodexMapper.map(r.json)
        let plan = CodexMapper.formatPlan(r.json["plan_type"])
        let credits = CodexMapper.formatCredits(r.json)
        return ProviderFetchResult(lines: lines, planName: plan, extraUsageText: credits)
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

/// Thread-safe in-memory cache for Antigravity's refreshed access token and plan tier so we don't refresh on every cycle.
private final class InMemoryTokenCache: @unchecked Sendable {
    static let shared = InMemoryTokenCache()
    private let lock = NSLock()
    private var access: String?
    private var expiry: Date?
    private var planName: String?

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

    func getPlan() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return planName
    }

    func setPlan(_ plan: String) {
        lock.lock()
        defer { lock.unlock() }
        planName = plan
    }
}

enum AntigravityMapper {
    static let argonGroupName = "Gemini 4 Argon"
    static let paidTierPlans = [
        "g1-pro-tier": "Pro",
        "g1-ultra-tier": "Ultra",
        "g1-ultra-lite-tier": "Ultra Lite",
    ]

    static func parsePlan(from loadCodeAssistBody: [String: Any]) -> String? {
        if let paid = loadCodeAssistBody["paidTier"] as? [String: Any] {
            if let id = paid["id"] as? String, let mapped = paidTierPlans[id] { return mapped }
            if let name = paid["name"] as? String, let f = formatTierText(name) { return f }
        }
        if let curr = loadCodeAssistBody["currentTier"] as? [String: Any],
           let name = curr["name"] as? String,
           let f = formatTierText(name) {
            return f
        }
        return nil
    }

    private static func formatTierText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for kw in ["Ultra", "Pro", "Free"] where trimmed.lowercased().contains(kw.lowercased()) {
            return kw
        }
        return nil
    }

    static let buckets: [(id: String, label: String, kind: WindowKind, pool: String)] = [
        ("gemini-5h", "Gemini · 5H", .session, "gemini"),
        ("gemini-weekly", "Gemini · 7D", .weekly, "gemini"),
        ("3p-5h", "Claude/GPT · 5H", .session, "3p"),
        ("3p-weekly", "Claude/GPT · 7D", .weekly, "3p"),
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
                            label: "Gemini 4 Argon · 7D",
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
        try await fetchResult().lines
    }

    func fetchResult() async throws -> ProviderFetchResult {
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

        var plan = InMemoryTokenCache.shared.getPlan()
        if plan == nil {
            plan = await fetchPlanName(token: activeToken)
            if let plan { InMemoryTokenCache.shared.setPlan(plan) }
        }
        if plan == nil && lines.contains(where: { $0.id == "argon-weekly" }) {
            plan = "Pro"
        }
        return ProviderFetchResult(lines: lines, planName: plan)
    }

    private func fetchPlanName(token: String) async -> String? {
        let payload = Data(#"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)
        for host in Self.hosts.reversed() {
            var req = URLRequest(url: URL(string: host + "/v1internal:loadCodeAssist")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = payload
            if let r = try? await http.send(req), r.status == 200,
               let plan = AntigravityMapper.parsePlan(from: r.json) {
                return plan
            }
        }
        return nil
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
