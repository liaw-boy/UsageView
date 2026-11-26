import Foundation
import XCTest
@testable import QuotaBarCore

private struct FakeCredentials: CredentialSource {
    let json: String
    init(oauth: [String: Any]) {
        json = String(decoding: try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]), as: UTF8.self)
    }
    func keychain(service: String, account: String?) -> String? { json }
    func file(_ path: String) -> Data? { nil }
    func env(_ key: String) -> String? { nil }
}

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: String
    private(set) var calls = 0
    init(status: Int, body: String) { self.status = status; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class ClaudeAvailabilityTests: XCTestCase {
    private func run(oauth: [String: Any], status: Int = 200, body: String = "{}") async -> (Error?, Int) {
        let transport = FakeTransport(status: status, body: body)
        let runtime = ClaudeRuntime(http: HTTPClient(transport: transport), credentials: FakeCredentials(oauth: oauth))
        do {
            _ = try await runtime.fetchResult()
            return (nil, transport.calls)
        } catch {
            return (error, transport.calls)
        }
    }

    func testTokenWithoutUsageScopeIsNotSentToTheAPI() async {
        let (error, calls) = await run(oauth: ["accessToken": "tok-demo", "scopes": ["user:inference"]])
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(error as? ProviderError, .notAvailable(ClaudeMapper.missingScopeMessage))
    }

    func testMissingScopesListStillQueries() async {
        let (error, calls) = await run(oauth: ["accessToken": "tok-demo"],
                                       body: #"{"five_hour":{"utilization":12},"seven_day":{"utilization":3}}"#)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(error)
    }

    func testEmptyOrMalformedScopesStillQuery() async {
        let ok = #"{"five_hour":{"utilization":1}}"#
        for scopes in [[], "user:inference user:profile"] as [Any] {
            let (error, calls) = await run(oauth: ["accessToken": "tok-demo", "scopes": scopes], body: ok)
            XCTAssertEqual(calls, 1)
            XCTAssertNil(error)
        }
    }

    func testNullSessionWindowWithOtherWindowStillShows() throws {
        let lines = try ClaudeMapper.map(["five_hour": NSNull(), "seven_day": ["utilization": 40]])
        XCTAssertEqual(lines.map(\.id), ["seven_day"])
    }

    func testFreeAccountWithNullWindowsIsNotAvailable() async {
        let (error, _) = await run(oauth: ["accessToken": "tok-demo", "scopes": ["user:inference", "user:profile"]],
                                   body: #"{"five_hour":null,"seven_day":null}"#)
        XCTAssertEqual(error as? ProviderError, .notAvailable(ClaudeMapper.noSubscriptionMessage))
    }

    func testScopeDenied403IsNotAvailable() async {
        let body = #"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement user:profile"}}"#
        let (error, _) = await run(oauth: ["accessToken": "tok-demo"], status: 403, body: body)
        XCTAssertEqual(error as? ProviderError, .notAvailable(ClaudeMapper.missingScopeMessage))
    }

    func testOther403StillMeansExpiredLogin() async {
        let (error, _) = await run(oauth: ["accessToken": "tok-demo"], status: 403, body: "{}")
        guard case .unauthorized = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
    }

    func testUnrecognisedBodyIsStillAParseError() {
        XCTAssertThrowsError(try ClaudeMapper.map(["unexpected": 1])) { XCTAssertEqual($0 as? ProviderError, .parse) }
    }
}
