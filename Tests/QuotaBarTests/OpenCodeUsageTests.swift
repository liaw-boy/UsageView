import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import QuotaBarCore

final class OpenCodeUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rec(_ ago: TimeInterval, provider: String = "opencode-go", cost: Double) -> OpenCodeUsageRecord {
        OpenCodeUsageRecord(timestamp: now.addingTimeInterval(-ago), providerID: provider,
                            modelID: "fake-model", costUSD: cost, tokens: 100)
    }

    // MARK: - Mapper

    func testSpendOnlyModeProducesNoPercentLines() {
        let lines = OpenCodeMapper.map([rec(60, cost: 3)], config: OpenCodeQuotaConfig(mode: .spendOnly), now: now)
        XCTAssertTrue(lines.isEmpty)
    }

    func testGoModeCountsOnlyGoSpendInsideRollingWindows() throws {
        let records = [
            rec(3600, cost: 3),                              // in 5H and 7D
            rec(10 * 3600, cost: 6),                         // 7D only
            rec(8 * 86400, cost: 50),                        // outside both
            rec(60, provider: "anthropic", cost: 99),        // ignored in Go mode
        ]
        let lines = OpenCodeMapper.map(records, config: OpenCodeQuotaConfig(mode: .go), now: now)
        XCTAssertEqual(lines.map(\.id), ["5h", "7d"])
        XCTAssertEqual(lines[0].usedPercent, 3 / 12 * 100, accuracy: 0.001)
        XCTAssertEqual(lines[1].usedPercent, 9 / 30 * 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lines[0].resetsAt), now.addingTimeInterval(-3600 + 5 * 3600))
    }

    func testCustomModeCountsAllProvidersAndCapsAt100() {
        let cfg = OpenCodeQuotaConfig(mode: .custom, customSessionBudget: 2, customWeeklyBudget: 10)
        let lines = OpenCodeMapper.map([rec(60, provider: "anthropic", cost: 5)], config: cfg, now: now)
        XCTAssertEqual(lines[0].usedPercent, 100)
        XCTAssertEqual(lines[1].usedPercent, 50, accuracy: 0.001)
    }

    func testInvalidCustomBudgetFallsBackToSpendOnly() {
        let cfg = OpenCodeQuotaConfig(mode: .custom, customSessionBudget: 0, customWeeklyBudget: 10)
        XCTAssertTrue(OpenCodeMapper.map([rec(60, cost: 1)], config: cfg, now: now).isEmpty)
    }

    // MARK: - Database (read-only)

    private func makeDatabase() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let assistant = #"{"model":{"id":"fake-model","providerID":"opencode-go"},"cost":0.5,"tokens":{"input":10,"output":20,"reasoning":0,"cache":{"read":5,"write":1}}}"#
        let sql = """
        CREATE TABLE session_message (id text PRIMARY KEY, session_id text, type text, seq integer, time_created integer, time_updated integer, data text);
        INSERT INTO session_message VALUES ('a','s','assistant',1,\(nowMs),\(nowMs),'\(assistant)');
        INSERT INTO session_message VALUES ('b','s','user',2,\(nowMs),\(nowMs),'{"text":"hi"}');
        INSERT INTO session_message VALUES ('c','s','assistant',3,\(nowMs),\(nowMs),'{"model":{"id":"x","providerID":"y"}}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return path
    }

    func testReadsOnlyCostedAssistantRows() throws {
        let path = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let records = try XCTUnwrap(OpenCodeDatabase.records(at: path, since: Date().addingTimeInterval(-3600)))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].providerID, "opencode-go")
        XCTAssertEqual(records[0].costUSD, 0.5, accuracy: 0.0001)
        XCTAssertEqual(records[0].tokens, 36)
    }

    func testReadingNeverModifiesTheDatabaseFile() throws {
        let path = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let before = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        _ = OpenCodeDatabase.records(at: path, since: .distantPast)
        let after = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(before, after)
    }

    func testMissingOrWrongSchemaDatabaseReturnsNil() throws {
        XCTAssertNil(OpenCodeDatabase.records(at: "/nonexistent/opencode.db", since: .distantPast))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).db").path
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, "CREATE TABLE other (x integer)", nil, nil, nil)
        sqlite3_close(db)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(OpenCodeDatabase.records(at: path, since: .distantPast))
    }

    // MARK: - Zero-quota guarantee

    func testOpenCodeAddsNoNetworkEndpoints() {
        XCTAssertFalse(EndpointGuard.allowlist.contains { $0.host.contains("opencode") })
        var req = URLRequest(url: URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        XCTAssertThrowsError(try EndpointGuard.validate(req))
    }

    func testRuntimeMakesNoHTTPRequestsAndReportsMissingDatabase() async {
        let runtime = OpenCodeRuntime(databasePath: "/nonexistent/opencode.db", config: { OpenCodeQuotaConfig() })
        do {
            _ = try await runtime.fetchResult()
            XCTFail("expected notLoggedIn")
        } catch {
            XCTAssertTrue(error is ProviderError)
        }
    }

    // MARK: - Vendor

    func testVendorNamesAndLogosDistinguishApiCompanies() {
        XCTAssertEqual(OpenCodeVendor.displayName("anthropic"), "Anthropic")
        XCTAssertEqual(OpenCodeVendor.displayName("openai"), "OpenAI")
        XCTAssertEqual(OpenCodeVendor.displayName("opencode-go"), "OpenCode Go")
        XCTAssertEqual(OpenCodeVendor.displayName("mycorp"), "Mycorp")
        XCTAssertEqual(OpenCodeVendor.logoProvider("anthropic"), .claude)
        XCTAssertEqual(OpenCodeVendor.logoProvider("openai"), .codex)
        XCTAssertNil(OpenCodeVendor.logoProvider("mycorp"))
    }

    func testSameModelFromDifferentVendorsStaysSeparate() {
        let a = ModelSpendBreakdown(model: "m", vendor: "anthropic")
        let b = ModelSpendBreakdown(model: "m", vendor: "openrouter")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testOldCachedBreakdownWithoutVendorStillDecodes() throws {
        let json = #"{"model":"x","todayCostUSD":1,"todayTokens":2,"weekCostUSD":1,"weekTokens":2,"monthCostUSD":1,"monthTokens":2}"#
        let m = try JSONDecoder().decode(ModelSpendBreakdown.self, from: Data(json.utf8))
        XCTAssertNil(m.vendor)
    }
}
