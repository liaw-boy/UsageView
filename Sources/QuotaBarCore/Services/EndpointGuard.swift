import Foundation

/// The single choke point for network safety.
///
/// UsageView must never consume quota or alter account state. Only the read-only usage endpoints
/// (plus Google's OAuth token endpoint for Antigravity's in-memory access token and GitHub's release
/// check endpoint) are allowed. Anything else — inference endpoints, rate-limit reset / credit consume
/// endpoints, or rotating Claude/Codex OAuth token refresh — is rejected before a byte leaves the machine.
public enum EndpointGuard {
    public struct Endpoint: Sendable, Equatable {
        public let method: String
        public let host: String
        public let path: String
    }

    public static let allowlist: [Endpoint] = [
        // Claude Code's own `/usage` read.
        .init(method: "GET", host: "api.anthropic.com", path: "/api/oauth/usage"),
        // Codex CLI's own `/status` read.
        .init(method: "GET", host: "chatgpt.com", path: "/backend-api/wham/usage"),
        // Antigravity quota summary (gRPC-style POST with empty `{}` body, read-only).
        .init(method: "POST", host: "cloudcode-pa.googleapis.com", path: "/v1internal:retrieveUserQuotaSummary"),
        .init(method: "POST", host: "daily-cloudcode-pa.googleapis.com", path: "/v1internal:retrieveUserQuotaSummary"),
        // Google OAuth access-token exchange (Google refresh tokens do not rotate; kept in memory only).
        .init(method: "POST", host: "oauth2.googleapis.com", path: "/token"),
        // Read-only GitHub Release check for self-update.
        .init(method: "GET", host: "api.github.com", path: "/repos/liaw-boy/UsageView/releases/latest"),
    ]

    public struct Blocked: LocalizedError, Equatable {
        public let description: String
        public var errorDescription: String? { "已阻擋非白名單請求：\(description)" }
    }

    public static func validate(_ request: URLRequest) throws {
        let method = (request.httpMethod ?? "GET").uppercased()
        guard let url = request.url,
              url.scheme == "https",
              let host = url.host?.lowercased()
        else { throw Blocked(description: "\(method) \(request.url?.absoluteString ?? "<nil>")") }

        let path = url.path
        // Query strings are not allowed either: e.g. `?cedar_ember=1` opts into reset grants.
        let hasQuery = !(url.query ?? "").isEmpty
        let ok = !hasQuery && allowlist.contains { $0.method == method && $0.host == host && $0.path == path }
        guard ok else { throw Blocked(description: "\(method) \(url.absoluteString)") }
    }
}
