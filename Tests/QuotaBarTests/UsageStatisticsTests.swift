import Foundation
import XCTest
@testable import QuotaBarCore

final class UsageStatisticsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2030-06-10 15:30 UTC, a Monday.
    private let now = Date(timeIntervalSince1970: 1_907_335_800)

    private func record(_ hoursAgo: Double, tokens: Int = 100, cost: Double = 1, project: String? = nil,
                        sidechain: Bool = false) -> LocalUsageScanner.Record {
        .init(timestamp: now.addingTimeInterval(-hoursAgo * 3600), tokens: tokens, costUSD: cost,
              isSidechain: sidechain, model: "claude-sonnet-4-6", project: project)
    }

    // MARK: - Summary

    func testSummaryBuildsHeatmapSidechainAndProjects() throws {
        let records = [
            record(0, project: "demo-app"),
            record(1, tokens: 50, cost: 2, project: "demo-app", sidechain: true),
            record(24 * 3, cost: 4, project: "sample-api"),
            record(24 * 10, project: "demo-app"),
            record(24 * 40, project: "too-old"),
        ]
        let s = try XCTUnwrap(LocalUsageScanner.summarize(records, provider: .claude, now: now, calendar: cal))
        XCTAssertEqual(s.hourlyTokens.count, 168)
        let todayIdx = 6 * 24 // last row is today
        XCTAssertEqual(s.hourlyTokens[todayIdx + 15], 100)
        XCTAssertEqual(s.hourlyTokens[todayIdx + 14], 50)
        XCTAssertEqual(s.hourlyRequests[todayIdx + 15], 1)
        XCTAssertEqual(s.hourlyTokens[3 * 24 + 15], 100, "3 days ago lands three rows above today")
        XCTAssertEqual(s.hourlyTokens.reduce(0, +), 250, "only the last 7 days are in the grid")
        XCTAssertEqual(s.hourlyRequests.reduce(0, +), 3)
        XCTAssertEqual(s.sidechainTokens, 50)
        XCTAssertEqual(s.projects.map(\.name), ["demo-app", "sample-api"])
        XCTAssertEqual(s.projects[0].monthCostUSD, 4, accuracy: 0.001)
        XCTAssertEqual(s.projects[0].weekCostUSD, 3, accuracy: 0.001)
        XCTAssertFalse(s.projects.contains { $0.name == "too-old" })
    }

    func testHourlyGridsRebaseToTodayAfterMidnight() throws {
        let s = try XCTUnwrap(LocalUsageScanner.summarize([record(0)], provider: .claude, now: now, calendar: cal))
        XCTAssertEqual(s.hourlyGrids(asOf: now, calendar: cal).tokens[6 * 24 + 15], 100)
        let tomorrow = now.addingTimeInterval(86_400)
        let next = s.hourlyGrids(asOf: tomorrow, calendar: cal)
        XCTAssertEqual(next.tokens[5 * 24 + 15], 100, "yesterday's usage moves up one row")
        XCTAssertEqual(next.tokens[6 * 24 ..< 7 * 24].reduce(0, +), 0, "the new today starts empty")
        XCTAssertEqual(next.requests[5 * 24 + 15], 1)
        XCTAssertEqual(s.hourlyGrids(asOf: now.addingTimeInterval(8 * 86_400), calendar: cal).tokens.reduce(0, +), 0)
    }

    func testOldCachedSummaryWithoutNewFieldsStillDecodes() throws {
        let json = #"{"todayCostUSD":1,"todayTokens":2,"monthCostUSD":3,"monthTokens":4}"#
        let s = try JSONDecoder().decode(LocalSpendSummary.self, from: Data(json.utf8))
        XCTAssertEqual(s.hourlyTokens, [])
        XCTAssertEqual(s.sidechainTokens, 0)
        XCTAssertEqual(s.projects, [])
    }

    // MARK: - Project names from logs

    func testProjectNameOnlyKeepsFolderName() {
        XCTAssertEqual(LocalUsageScanner.projectName("/work/demo-app"), "demo-app")
        XCTAssertEqual(LocalUsageScanner.projectName(#"\/work\/demo-app"#), "demo-app")
        XCTAssertNil(LocalUsageScanner.projectName("relative/path"))
        XCTAssertNil(LocalUsageScanner.projectName("/"))
        XCTAssertNil(LocalUsageScanner.projectName(nil))
    }

    func testClaudeAndCodexParsersAttachProject() {
        let claude = #"{"cwd":"/work/demo-app","type":"assistant","timestamp":"2030-06-12T10:00:00Z","requestId":"r1","message":{"id":"msg_1","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n"
        XCTAssertEqual(LocalUsageScanner.parseClaudeJSONL(Data(claude.utf8)).first?.project, "demo-app")

        let codex = [
            #"{"type":"session_meta","payload":{"cwd":"/work/sample-api"}}"#,
            #"{"type":"event_msg","timestamp":"2030-06-12T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(LocalUsageScanner.parseCodexJSONL(Data(codex.utf8)).first?.project, "sample-api")
    }

    // MARK: - Insights

    private func day(_ offset: Int, cost: Double, tokens: Int = 10) -> DailyUsageItem {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return DailyUsageItem(date: f.string(from: cal.date(byAdding: .day, value: -offset, to: now)!), tokens: tokens, costUSD: cost)
    }

    func testInsightsStreakPeakAndProjection() {
        // Today empty, yesterday + 2 days before active, gap, then an older peak day (same month: June 10 → June 3).
        let daily = [day(0, cost: 0, tokens: 0), day(1, cost: 7), day(2, cost: 7), day(3, cost: 7), day(7, cost: 50)]
        let i = UsageInsights.compute(daily: daily, now: now, calendar: cal)
        XCTAssertEqual(i.streakDays, 3, "an empty today must not break the streak")
        XCTAssertEqual(i.activeDays, 4)
        XCTAssertEqual(i.peakDay?.costUSD, 50)
        XCTAssertEqual(i.monthToDateUSD, 71, accuracy: 0.001)
        // last 7 days (today..6 days ago) = 21 → 3/day; June has 30 days, 20 remain after the 10th.
        XCTAssertEqual(i.projectedMonthUSD, 71 + 3 * 20, accuracy: 0.001)
    }

    func testInsightsOnEmptyHistory() {
        let i = UsageInsights.compute(daily: [], now: now, calendar: cal)
        XCTAssertNil(i.peakDay)
        XCTAssertEqual(i.streakDays, 0)
        XCTAssertEqual(i.projectedMonthUSD, 0)
    }

    // MARK: - Quota history

    private func snap(_ used: Double, reset: Date?, weekly: Double? = nil) -> ProviderSnapshot {
        var lines = [MetricLine(id: "5h", label: "5H", kind: .session, usedPercent: used, resetsAt: reset)]
        if let weekly { lines.append(MetricLine(id: "7d", label: "7D", kind: .weekly, usedPercent: weekly, resetsAt: nil)) }
        return ProviderSnapshot(provider: .claude, lines: lines)
    }

    @MainActor
    func testHistoryRecordsChangesHeartbeatAndRetention() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QuotaHistoryStore(url: url)
        let reset = now.addingTimeInterval(3600)

        XCTAssertTrue(store.record(snap(10, reset: reset, weekly: 40), now: now))
        XCTAssertEqual(store.samples.count, 2)
        XCTAssertFalse(store.record(snap(10.2, reset: reset.addingTimeInterval(5), weekly: 40), now: now.addingTimeInterval(60)),
                       "tiny change in the same window is skipped")
        XCTAssertTrue(store.record(snap(25, reset: reset, weekly: 40), now: now.addingTimeInterval(120)))
        XCTAssertEqual(store.series(.claude, .session, since: .distantPast).map(\.used), [10, 25])
        XCTAssertTrue(store.record(snap(25, reset: reset, weekly: 40), now: now.addingTimeInterval(120 + QuotaHistoryStore.heartbeat)),
                      "unchanged values are re-recorded after the heartbeat")

        XCTAssertEqual(QuotaHistoryStore(url: url).samples, store.samples, "history survives a restart")

        let later = now.addingTimeInterval(QuotaHistoryStore.retention + 7200)
        store.record(snap(5, reset: later.addingTimeInterval(3600)), now: later)
        XCTAssertTrue(store.samples.allSatisfy { later.timeIntervalSince($0.at) <= QuotaHistoryStore.retention })
    }

    @MainActor
    func testHistoryKeepsReadableSamplesAndSetsAsideCorruptFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mixed = dir.appendingPathComponent("mixed.json")
        try Data(#"[{"provider":"future-ai","kind":"session","used":5,"at":1},{"provider":"claude","kind":"session","used":42,"at":2}]"#.utf8)
            .write(to: mixed)
        XCTAssertEqual(QuotaHistoryStore(url: mixed).samples.map(\.used), [42], "unknown entries are skipped, the rest kept")

        let broken = dir.appendingPathComponent("broken.json")
        try Data(#"[{"provider":"claude","kind":"sess"#.utf8).write(to: broken)
        let store = QuotaHistoryStore(url: broken)
        XCTAssertTrue(store.samples.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0 == "broken.json.corrupt" }, "the unreadable file is kept aside, not overwritten")
    }

    func testWindowPeaksDoNotSplitAcrossBucketEdges() {
        let edge = Date(timeIntervalSince1970: 1_907_335_800 + 300) // xx:05:00
        let samples = [
            QuotaSample(provider: .claude, kind: .session, used: 40, resetsAt: edge.addingTimeInterval(-2), at: now),
            QuotaSample(provider: .claude, kind: .session, used: 70, resetsAt: edge.addingTimeInterval(3), at: now),
        ]
        XCTAssertEqual(QuotaHistoryStore.windowPeaks(samples).map(\.peak), [70])
    }

    func testWindowPeaksGroupJitteringResetTimes() {
        let r1 = now, r2 = now.addingTimeInterval(5 * 3600)
        let samples = [
            QuotaSample(provider: .claude, kind: .session, used: 30, resetsAt: r1, at: now),
            QuotaSample(provider: .claude, kind: .session, used: 80, resetsAt: r1.addingTimeInterval(20), at: now),
            QuotaSample(provider: .claude, kind: .session, used: 15, resetsAt: r2, at: now),
            QuotaSample(provider: .claude, kind: .session, used: 99, resetsAt: nil, at: now),
        ]
        let peaks = QuotaHistoryStore.windowPeaks(samples)
        XCTAssertEqual(peaks.map(\.peak), [15, 80])
    }
}
