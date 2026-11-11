import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Refuses every redirect: `EndpointGuard` only vets the original URL, so following a redirect could carry a
/// Bearer token to a host that was never allow-listed. The 3xx response is returned to the caller as an error.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)

    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
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

/// Debug trace for `QUOTABAR_LOG=1`. Goes to stderr, which is unbuffered, so lines survive a redirect or a crash.
func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["QUOTABAR_LOG"] == "1" else { return }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write(Data("[QuotaBar \(f.string(from: Date()))] \(message)\n".utf8))
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
        let response: HTTPURLResponse
        let data: Data
        do {
            (data, response) = try await transport.send(request)
        } catch {
            debugLog("\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "") failed: \(error.localizedDescription)")
            throw error
        }
        let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After") ?? "-"
        debugLog("\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "") → \(response.statusCode) retry-after=\(retryAfterHeader)")
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
