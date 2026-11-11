import Charts
import QuotaBarCore
import SwiftUI

/// Extra statistics shown only in the main window: headline numbers, provider comparison, hour-of-week heatmap,
/// per-project spend and quota history. Everything is computed locally from data the app already has.
struct UsageInsightsSections: View {
    let daily: [DailyUsageItem]
    let hourly: [Int]
    let hourlyRequests: [Int]
    let monthTokens: Int
    let sidechainTokens: Int
    let projects: [ProjectSpend]
    let perProvider: [(id: ProviderID, summary: LocalSpendSummary)]
    let quotaProviders: [ProviderID]
    let history: QuotaHistoryStore

    @State private var historyProvider: ProviderID?
    @State private var historyKind: WindowKind = .session
    @State private var showAllProjects = false

    private static let costGreen = Color(red: 0.35, green: 0.88, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            overview
            if perProvider.count > 1 { comparison }
            if hourly.contains(where: { $0 > 0 }) { heatmap }
            if !projects.isEmpty { projectSection }
            if !quotaProviders.isEmpty { quotaHistory }
        }
    }

    // MARK: - Overview

    private var overview: some View {
        let i = UsageInsights.compute(daily: daily)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("總覽", note: "依近 30 天本機紀錄估算")
            HStack(spacing: 8) {
                tile("本月推估", value: money(i.projectedMonthUSD), sub: "本月至今 \(money(i.monthToDateUSD))", tint: Self.costGreen)
                tile("尖峰日", value: i.peakDay.map { shortDate($0.date) } ?? "—",
                     sub: i.peakDay.map { "\(money($0.costUSD)) · \(tokens($0.tokens))" } ?? "尚無紀錄")
                tile("連續使用", value: "\(i.streakDays) 天", sub: "近 30 天有 \(i.activeDays) 天使用")
                if sidechainTokens > 0, monthTokens > 0 {
                    tile("Subagent 佔比", value: percent(Double(sidechainTokens) / Double(monthTokens)),
                         sub: "\(tokens(sidechainTokens)) tokens")
                }
            }
        }
    }

    private func tile(_ title: String, value: String, sub: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Provider comparison

    private struct DayPoint: Identifiable {
        let id = UUID()
        let date: Date
        let provider: ProviderID
        let cost: Double
    }

    private var comparison: some View {
        let total = max(perProvider.reduce(0) { $0 + $1.summary.monthCostUSD }, 0.0001)
        let points = perProvider.flatMap { p in
            p.summary.dailyHistory.compactMap { d in parseDate(d.date).map { DayPoint(date: $0, provider: p.id, cost: d.costUSD) } }
        }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("各家 AI 對比", note: "近 30 天")
            VStack(spacing: 6) {
                ForEach(perProvider.sorted { $0.summary.monthCostUSD > $1.summary.monthCostUSD }, id: \.id) { p in
                    let share = p.summary.monthCostUSD / total
                    HStack(spacing: 8) {
                        ProviderLogoView(provider: p.id, size: 12, tinted: true)
                        Text(p.id.displayName).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85)).frame(width: 92, alignment: .leading)
                        bar(share, color: Theme.brandColor(p.id))
                        Text("\(money(p.summary.monthCostUSD)) · \(tokens(p.summary.monthTokens))")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                            .frame(width: 150, alignment: .trailing)
                        Text(percent(share)).font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85)).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Chart(points) { pt in
                BarMark(x: .value("日期", pt.date, unit: .day), y: .value("花費", pt.cost))
                    .foregroundStyle(by: .value("AI", pt.provider.displayName))
            }
            .chartForegroundStyleScale(domain: perProvider.map(\.id.displayName),
                                       range: perProvider.map { Theme.brandColor($0.id) })
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
            .chartXScale(range: .plotDimension(endPadding: 14))
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 150)
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Heatmap (last 7 days × 24 hours, today at the bottom)

    private var heatmap: some View {
        let cell: CGFloat = 15, gap: CGFloat = 3
        let maxValue = max(hourly.max() ?? 1, 1)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
        func label(_ row: Int) -> String {
            guard row < 6, let d = cal.date(byAdding: .day, value: row - 6, to: today) else { return "今" }
            return weekdayNames[cal.component(.weekday, from: d) - 1]
        }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("使用時段", note: "近 7 天 · 每小時 token")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        HStack(spacing: gap) {
                            Text(label(row))
                                .font(.system(size: 9.5, weight: row == 6 ? .bold : .medium))
                                .foregroundStyle(.white.opacity(row == 6 ? 0.9 : 0.5))
                                .frame(width: 14)
                            ForEach(0..<24, id: \.self) { h in
                                let i = row * 24 + h
                                let v = i < hourly.count ? hourly[i] : 0
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(v == 0 ? Color.white.opacity(0.05)
                                          : Self.costGreen.opacity(0.18 + 0.82 * Double(v) / Double(maxValue)))
                                    .frame(width: cell, height: cell)
                                    .help("\(label(row) == "今" ? "今天" : "週" + label(row)) \(h):00 · \(tokens(v)) tokens · \(requests(i)) 次")
                            }
                        }
                    }
                    HStack(spacing: gap) {
                        Color.clear.frame(width: 14, height: 1)
                        ForEach(0..<24, id: \.self) { h in
                            Text(h % 6 == 0 ? "\(h)" : "").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                                .frame(width: cell, alignment: .leading).fixedSize()
                        }
                    }
                }
                todaySummary
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func requests(_ i: Int) -> Int { i < hourlyRequests.count ? hourlyRequests[i] : 0 }

    private var todaySummary: some View {
        let todayRange = 144..<min(168, hourly.count)
        let todayTok = todayRange.reduce(0) { $0 + hourly[$1] }
        let todayReq = todayRange.reduce(0) { $0 + requests($1) }
        let busiestToday = todayRange.max { hourly[$0] < hourly[$1] }.flatMap { hourly[$0] > 0 ? $0 % 24 : nil }
        let dailyAvg = Double(hourly.reduce(0, +)) / 7
        // Busiest hour of the week by reply count.
        let weekBusiest = hourlyRequests.indices.max { hourlyRequests[$0] < hourlyRequests[$1] }
            .flatMap { hourlyRequests[$0] > 0 ? $0 : nil }
        let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
        func dayName(_ row: Int) -> String {
            guard row < 6, let d = Calendar.current.date(byAdding: .day, value: row - 6, to: Calendar.current.startOfDay(for: Date()))
            else { return "今天" }
            return "週" + weekdayNames[Calendar.current.component(.weekday, from: d) - 1]
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text("今天").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Self.costGreen)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tokens(todayTok)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .monospacedDigit()
                Text("tokens").font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            Group {
                Text("\(todayReq) 次回覆" + (busiestToday.map { " · 最忙 \($0) 時" } ?? ""))
                if dailyAvg > 0 {
                    Text("7 天日均 \(tokens(Int(dailyAvg)))，今天是 \(percent(Double(todayTok) / dailyAvg))")
                }
                if let w = weekBusiest {
                    Text("本週最忙：\(dayName(w / 24)) \(w % 24) 時（\(hourlyRequests[w]) 次）")
                }
            }
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Projects

    private var projectSection: some View {
        let shown = showAllProjects ? projects : Array(projects.prefix(8))
        let top = max(projects.first?.monthCostUSD ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("依專案", note: "近 30 天 · 依工作資料夾名稱")
            VStack(spacing: 6) {
                ForEach(shown) { p in
                    HStack(spacing: 8) {
                        Text(p.name).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88)).lineLimit(1).truncationMode(.middle)
                            .frame(width: 150, alignment: .leading)
                        bar(p.monthCostUSD / top, color: Self.costGreen)
                        Text("7D \(money(p.weekCostUSD))").font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5)).frame(width: 90, alignment: .trailing)
                        Text(money(p.monthCostUSD)).font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Self.costGreen).frame(width: 80, alignment: .trailing)
                    }
                    .help("\(p.name) · \(tokens(p.monthTokens)) tokens")
                }
            }
            if projects.count > 8 {
                Button(showAllProjects ? "收合" : "顯示全部 \(projects.count) 個專案") { showAllProjects.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Quota history

    private var quotaHistory: some View {
        let provider = historyProvider.flatMap { quotaProviders.contains($0) ? $0 : nil } ?? quotaProviders[0]
        let window: TimeInterval = historyKind == .session ? 2 * 86_400 : 30 * 86_400
        let series = history.series(provider, historyKind, since: Date().addingTimeInterval(-window))
        let peaks = Array(QuotaHistoryStore.windowPeaks(history.series(provider, historyKind, since: .distantPast))
            .filter { $0.resetsAt <= Date() }.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("額度歷史", note: historyKind == .session ? "近 48 小時 · 已用 %" : "近 30 天 · 已用 %")
                Spacer()
                if quotaProviders.count > 1 {
                    ForEach(quotaProviders, id: \.self) { p in
                        chip(p.displayName, selected: p == provider) { historyProvider = p }
                    }
                }
                chip("5H", selected: historyKind == .session) { historyKind = .session }
                chip("7D", selected: historyKind == .weekly) { historyKind = .weekly }
            }
            if series.count < 2 {
                Text("從這個版本開始在本機記錄額度變化，累積幾次更新後就會顯示曲線。")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                        LineMark(x: .value("時間", s.at), y: .value("已用", s.used))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Theme.brandColor(provider))
                        AreaMark(x: .value("時間", s.at), y: .value("已用", s.used))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Theme.brandColor(provider).opacity(0.12))
                    }
                    RuleMark(y: .value("警戒", 80))
                        .foregroundStyle(Color(red: 0.98, green: 0.76, blue: 0.22).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 80, 100]) { v in AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } } } }
                .frame(height: 140)
            }
            if !peaks.isEmpty {
                Text("最近幾次重置前用到").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 6) {
                    ForEach(peaks) { p in
                        VStack(spacing: 2) {
                            Text("\(Int(p.peak.rounded()))%").font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.ringColor(for: provider, usedPercent: p.peak))
                            Text(p.resetsAt, format: .dateTime.month(.defaultDigits).day().hour().minute())
                                .font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Pieces

    private func sectionTitle(_ title: String, note: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            if !note.isEmpty {
                Text(note).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func bar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }

    private func money(_ v: Double) -> String {
        v >= 1000 ? String(format: "$%.2fK", v / 1000) : String(format: "$%.2f", v)
    }

    private func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.2fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    private func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    private func shortDate(_ d: String) -> String {
        let parts = d.split(separator: "-")
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : d
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func parseDate(_ s: String) -> Date? { Self.dayParser.date(from: s) }
}
