import Foundation
import XCTest
@testable import QuotaBarCore

final class JSONCTextTests: XCTestCase {

    func testParsesCommentsAndTrailingCommas() throws {
        let text = """
        {
          // leading comment
          "a": 1, /* inline */
          "b": { "c": "x// not a comment", },
        }
        """
        let obj = try XCTUnwrap(JSONCText.object(text))
        XCTAssertEqual(obj["a"] as? Int, 1)
        XCTAssertEqual((obj["b"] as? [String: Any])?["c"] as? String, "x// not a comment")
    }

    func testRemovingNestedKeyKeepsCommentsOrderAndSiblings() throws {
        let text = """
        {
          "$schema": "https://opencode.ai/config.json",
          // keep this comment
          "mcp": {
            "servers": {
              "keep": { "type": "local", "command": ["npx", "a"] },
              "drop": {
                "type": "remote",
                "url": "https://e.com/mcp"
              }
            }
          },
          "model": "anthropic/x"
        }
        """
        let out = try JSONCText.removingKey(path: ["mcp", "servers", "drop"], in: text)
        XCTAssertFalse(out.contains("drop"))
        XCTAssertTrue(out.contains("// keep this comment"))
        XCTAssertTrue(out.contains("\"keep\""))
        XCTAssertTrue(out.contains("\"model\": \"anthropic/x\""))
        // Still valid and structurally correct
        let obj = try XCTUnwrap(JSONCText.object(out))
        let servers = try XCTUnwrap((obj["mcp"] as? [String: Any])?["servers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["keep"])
    }

    func testRemovingFirstKeyLeavesValidJSON() throws {
        let text = #"{"mcp":{"servers":{"a":{"type":"local"},"b":{"type":"remote"}}}}"#
        let out = try JSONCText.removingKey(path: ["mcp", "servers", "a"], in: text)
        let servers = try XCTUnwrap((JSONCText.object(out)?["mcp"] as? [String: Any])?["servers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["b"])
    }

    func testRemovingOnlyKeyLeavesEmptyObject() throws {
        let text = #"{"mcp":{"servers":{"only":{"type":"local"}}}}"#
        let out = try JSONCText.removingKey(path: ["mcp", "servers", "only"], in: text)
        let servers = try XCTUnwrap((JSONCText.object(out)?["mcp"] as? [String: Any])?["servers"] as? [String: Any])
        XCTAssertTrue(servers.isEmpty)
    }

    func testRemovingLegacyTopLevelShape() throws {
        let text = #"{"mcp":{"a":{"type":"local"},"b":{"type":"local"}}}"#
        let out = try JSONCText.removingKey(path: ["mcp", "b"], in: text)
        XCTAssertEqual(Array(try XCTUnwrap(JSONCText.object(out)?["mcp"] as? [String: Any]).keys), ["a"])
    }

    func testKeyLookalikesInsideStringsAreIgnored() throws {
        let text = #"{"mcp":{"servers":{"a":{"note":"\"drop\": here"},"drop":{"type":"local"}}}}"#
        let out = try JSONCText.removingKey(path: ["mcp", "servers", "drop"], in: text)
        let servers = try XCTUnwrap((JSONCText.object(out)?["mcp"] as? [String: Any])?["servers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["a"])
        XCTAssertTrue(out.contains(#"\"drop\": here"#))
    }

    func testMissingKeyThrowsAndMalformedThrows() {
        XCTAssertThrowsError(try JSONCText.removingKey(path: ["mcp", "servers", "nope"], in: #"{"mcp":{"servers":{}}}"#))
        XCTAssertThrowsError(try JSONCText.removingKey(path: ["mcp"], in: "{ not json"))
    }
}
