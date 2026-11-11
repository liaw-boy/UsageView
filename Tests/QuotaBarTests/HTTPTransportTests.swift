import Foundation
import XCTest
@testable import QuotaBarCore

final class HTTPTransportTests: XCTestCase {
    func testHTTPTransportRefusesRedirects() {
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.test/")!)
        let response = HTTPURLResponse(url: URL(string: "https://example.test/")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://evil.test/"])!
        let exp = expectation(description: "redirect decision")
        NoRedirectDelegate().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                                        newRequest: URLRequest(url: URL(string: "https://evil.test/")!)) { followed in
            XCTAssertNil(followed)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
