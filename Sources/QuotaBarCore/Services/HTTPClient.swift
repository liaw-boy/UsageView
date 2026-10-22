import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.parse }
        return (data, http)
    }
}

public struct HTTPResult: Sendable {
    public let status: Int
    public let data: Data
    public let retryAfter: TimeInterval?

    public var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Every request in the app goes through here, and therefore through `EndpointGuard`.
public struct HTTPClient: Sendable {
    let transport: HTTPTransport
    let log = ProcessInfo.processInfo.environment["QUOTABAR_LOG"] == "1"

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        var request = request
        request.timeoutInterval = 15
        do {
            try EndpointGuard.validate(request)
        } catch {
            if log { print("[QuotaBar] BLOCKED \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")") }
            throw error
        }
        let (data, response) = try await transport.send(request)
        if log { print("[QuotaBar] \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "") → \(response.statusCode)") }
        let retryAfter = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        return HTTPResult(status: response.statusCode, data: data, retryAfter: retryAfter)
    }
}

public enum ProviderError: LocalizedError, Equatable {
    case notLoggedIn(String)
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case parse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn(let m), .unauthorized(let m): m
        case .rateLimited: "請求太頻繁，稍後自動重試"
        case .http(let code): "伺服器回應 HTTP \(code)"
        case .parse: "無法解析回應"
        case .timeout: "更新逾時（120 秒）"
        }
    }

    /// Standard status handling shared by all providers.
    static func check(_ r: HTTPResult, unauthorizedHint: String) throws {
        switch r.status {
        case 200..<300: return
        case 401, 403: throw ProviderError.unauthorized(unauthorizedHint)
        case 429: throw ProviderError.rateLimited(retryAfter: r.retryAfter)
        default: throw ProviderError.http(r.status)
        }
    }
}
