import AppKit
import QuotaBarCore
import SwiftUI

/// Detailed Quota & Spend Statistics Table view (Token usage & Cost: Daily, Weekly, Monthly).
public struct UsageStatisticsView: View {
    @ObservedObject var store: SnapshotStore
    var initialProvider: ProviderID?
    var onBack: () -> Void
    var embedded = false

    @State private var selectedFilter: ProviderFilter = .all
    @State private var modelPeriod: MetricPeriod = .today
    @State private var copiedToast = false

    enum ProviderFilter: Hashable {
        case all
        case provider(ProviderID)

        var title: String {
            switch self {
            case .all: "全部加總"
            case .provider(let p): p.displayName
            }
        }
    }

    enum MetricPeriod: String, CaseIterable, Identifiable {
        case today = "當日"
        case week = "本週 (7D)"
        case month = "本月 (30D)"
        var id: String { rawValue }
    }

    public init(store: SnapshotStore, initialProvider: ProviderID? = nil, embedded: Bool = false, onBack: @escaping () -> Void) {
        self.embedded = embedded
        self.store = store
        self.initialProvider = initialProvider
        self.onBack = onBack
        if let initialProvider {
            _selectedFilter = State(initialValue: .provider(initialProvider))
        }
    }

    private var activeProviders: [ProviderID] {
        store.panelProviders.filter { p in
            guard let snap = store.states[p]?.snapshot, let s = snap.localSpend else { return false }
            return s.hasAnyUsage
        }
    }

    // MARK: - Aggregated Metrics

    private struct AggregatedStats {
        var todayCost: Double = 0
        var todayTok: Int = 0
        var weekCost: Double = 0
        var weekTok: Int = 0
        var monthCost: Double = 0
        var monthTok: Int = 0
        var models: [ModelSpendBreakdown] = []
        var dailyHistory: [DailyUsageItem] = []
    }

    private var currentStats: AggregatedStats {
        var res = AggregatedStats()
        let targets: [ProviderID]
        switch selectedFilter {
        case .all:
            targets = store.panelProviders
        case .provider(let p):
            targets = [p]
        }

        var modelMap: [String: ModelSpendBreakdown] = [:]
        var dayMap: [String: (tok: Int, cost: Double)] = [:]

        for p in targets {
            guard let snap = store.states[p]?.snapshot, let s = snap.localSpend else { continue }
            res.todayCost += s.todayCostUSD
            res.todayTok += s.todayTokens
            res.weekCost += s.weekCostUSD
            res.weekTok += s.weekTokens
            res.monthCost += s.monthCostUSD
            res.monthTok += s.monthTokens

            for m in s.models {
                let name = "\(m.vendor ?? "")|\(m.model)"
                let existing = modelMap[name]
                modelMap[name] = ModelSpendBreakdown(
                    model: m.model,
                    vendor: m.vendor,
                    todayCostUSD: (existing?.todayCostUSD ?? 0) + m.todayCostUSD,
                    todayTokens: (existing?.todayTokens ?? 0) + m.todayTokens,
                    weekCostUSD: (existing?.weekCostUSD ?? 0) + m.weekCostUSD,
                    weekTokens: (existing?.weekTokens ?? 0) + m.weekTokens,
                    monthCostUSD: (existing?.monthCostUSD ?? 0) + m.monthCostUSD,
                    monthTokens: (existing?.monthTokens ?? 0) + m.monthTokens
                )
            }

            for d in s.dailyHistory {
                var cur = dayMap[d.date] ?? (0, 0.0)
                cur.tok += d.tokens
                cur.cost += d.costUSD
                dayMap[d.date] = cur
            }
        }

        res.models = modelMap.values.sorted { ($0.monthCostUSD, $0.monthTokens) > ($1.monthCostUSD, $1.monthTokens) }
        res.dailyHistory = dayMap.map { DailyUsageItem(date: $0.key, tokens: $0.value.tok, costUSD: $0.value.cost) }
            .sorted { $0.date > $1.date }

        return res
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            providerPicker
            matrixTable
            modelBreakdownSection
            recentDailySection
            footerNote
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if embedded {
            PageHeader(title: "用量統計", subtitle: "Token 用量與 API 等效花費（估算）") { copyButton }
        } else {
            HStack(spacing: 6) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("額度面板")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("額度使用統計表")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                copyButton
            }
        }
    }

    private var copyButton: some View {
        Button {
            copyMarkdownTable()
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: copiedToast ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(copiedToast ? "已複製" : "複製")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(copiedToast ? Color(red: 0.30, green: 0.88, blue: 0.56) : .white.opacity(0.88))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(Theme.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("複製 Markdown 格式統計表格至剪貼簿")
    }

    // MARK: - Provider Filter

    @ViewBuilder
    private var providerPicker: some View {
        let filters: [ProviderFilter] = [.all] + activeProviders.map { .provider($0) }
        if filters.count > 2 {
            HStack(spacing: 6) {
                ForEach(filters, id: \.self) { item in
                    let selected = selectedFilter == item
                    Button {
                        selectedFilter = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 11.5, weight: selected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(selected ? .white : .white.opacity(0.70))
                            .padding(.horizontal, 10.5)
                            .padding(.vertical, 4.5)
                            .background(selected ? Color.white.opacity(0.20) : Color.white.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.35) : Color.clear, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Core Matrix Table (當日 / 本週 / 本月)

    private var matrixTable: some View {
        let stats = currentStats
        return VStack(spacing: 0) {
            // Header row
            HStack {
                Text("統計期間")
                    .frame(width: 92, alignment: .leading)
                Text("Token 用量")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("估算花費 (USD)")
                    .frame(width: 108, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.60))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))

            Divider().overlay(Color.white.opacity(0.10))

            // Row 1: 當日 (Today)
            tableRow(
                icon: "sun.max.fill",
                iconColor: Color(red: 0.98, green: 0.76, blue: 0.22),
                period: "當日",
                tokens: stats.todayTok,
                cost: stats.todayCost,
                isHighlight: true
            )

            Divider().overlay(Color.white.opacity(0.07))

            // Row 2: 本週 (7 Days)
            tableRow(
                icon: "calendar",
                iconColor: Color(red: 0.40, green: 0.75, blue: 1.0),
                period: "本週 (7D)",
                tokens: stats.weekTok,
                cost: stats.weekCost,
                isHighlight: false
            )

            Divider().overlay(Color.white.opacity(0.07))

            // Row 3: 本月 (30 Days)
            tableRow(
                icon: "chart.bar.doc.horizontal",
                iconColor: Color(red: 0.70, green: 0.50, blue: 1.0),
                period: "本月 (30D)",
                tokens: stats.monthTok,
                cost: stats.monthCost,
                isHighlight: false
            )
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    }

    private func tableRow(
        icon: String,
        iconColor: Color,
        period: String,
        tokens: Int,
        cost: Double,
        isHighlight: Bool
    ) -> some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(iconColor)
                Text(period)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatTokens(tokens))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if tokens > 0 {
                    Text(NumberFormatter.localizedString(from: NSNumber(value: tokens), number: .decimal))
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatCostMatrix(cost))
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.62))
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(String(format: "$%.2f", cost))
                let ntd = cost * 32.2
                Text("≈ NT$\(formatNTD(ntd))")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 108, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHighlight ? Color.white.opacity(0.03) : Color.clear)
    }

    // MARK: - Model Breakdown

    private var modelBreakdownSection: some View {
        let models = currentStats.models
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模型明細")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))

                Spacer()

                HStack(spacing: 2) {
                    ForEach(MetricPeriod.allCases) { p in
                        let isSel = modelPeriod == p
                        Button {
                            modelPeriod = p
                        } label: {
                            Text(p.rawValue)
                                .font(.system(size: 10.5, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isSel ? .white : .white.opacity(0.60))
                                .padding(.horizontal, 8.5)
                                .padding(.vertical, 3.5)
                                .background(isSel ? Color.white.opacity(0.20) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
            }
            .padding(.horizontal, 2)

            let maxCost = models.map { periodCost($0, period: modelPeriod) }.max() ?? 1.0
            let rankedModels = models.sorted {
                let cost0 = periodCost($0, period: modelPeriod)
                let cost1 = periodCost($1, period: modelPeriod)
                if cost0 != cost1 { return cost0 > cost1 }
                return periodTokens($0, period: modelPeriod) > periodTokens($1, period: modelPeriod)
            }
            // Models with no usage in the selected period only add noise; summarize them in one line.
            let sortedModels = rankedModels.filter {
                periodCost($0, period: modelPeriod) > 0 || periodTokens($0, period: modelPeriod) > 0
            }
            let idleCount = rankedModels.count - sortedModels.count

            VStack(spacing: 7) {
                if sortedModels.isEmpty {
                    Text("此期間無模型紀錄")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                } else {
                    ForEach(sortedModels) { m in
                        let cost = periodCost(m, period: modelPeriod)
                        let tok = periodTokens(m, period: modelPeriod)
                        let fraction = maxCost > 0 ? min(1.0, max(0.04, cost / maxCost)) : 0.04

                        VStack(alignment: .leading, spacing: 2.5) {
                            HStack {
                                if let vendor = m.vendor {
                                    VendorLogoView(vendor: vendor, size: 11)
                                }
                                Text(m.model)
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                if let vendor = m.vendor {
                                    Text(OpenCodeVendor.displayName(vendor))
                                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.62))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.08), in: Capsule())
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                Spacer(minLength: 4)
                                Text(formatTokens(tok))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                Text(formatCostCompact(cost))
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.62))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .frame(minWidth: 54, alignment: .trailing)
                                    .help(String(format: "$%.2f (約 NT$%d)", cost, Int((cost * 32.2).rounded())))
                            }

                            // Visual share bar
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.08))
                                        .frame(height: 4)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(red: 0.35, green: 0.88, blue: 0.62).opacity(0.78))
                                        .frame(width: proxy.size.width * fraction, height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                        .padding(.vertical, 2.5)
                    }
                    if idleCount > 0 {
                        Text("另有 \(idleCount) 個模型在此期間無用量")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(.white.opacity(0.40))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(9.5)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.8))
        }
    }

    private func periodCost(_ m: ModelSpendBreakdown, period: MetricPeriod) -> Double {
        switch period {
        case .today: m.todayCostUSD
        case .week: m.weekCostUSD
        case .month: m.monthCostUSD
        }
    }

    private func periodTokens(_ m: ModelSpendBreakdown, period: MetricPeriod) -> Int {
        switch period {
        case .today: m.todayTokens
        case .week: m.weekTokens
        case .month: m.monthTokens
        }
    }

    // MARK: - Recent Daily History (Last 5 Active Days)

    private var recentDailySection: some View {
        let history = Array(currentStats.dailyHistory.prefix(5))
        return VStack(alignment: .leading, spacing: 5) {
            Text("近期每日趨勢")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.80))
                .padding(.horizontal, 2)

            HStack(spacing: 5) {
                if history.isEmpty {
                    Text("暫無歷史資料")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    ForEach(history.reversed()) { item in
                        VStack(spacing: 2) {
                            Text(formatCostCompact(item.costUSD))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.62))
                                .monospacedDigit()
                                .lineLimit(1)
                                .help(String(format: "$%.2f", item.costUSD))
                            Text(shortDate(item.date))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.white.opacity(0.50))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5.5)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private func shortDate(_ d: String) -> String {
        // "2026-10-22" -> "10/22"
        let parts = d.split(separator: "-")
        if parts.count == 3 {
            return "\(parts[1])/\(parts[2])"
        }
        return d
    }

    // MARK: - Footer

    private var footerNote: some View {
        HStack(spacing: 4.5) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.62))
            Text("100% 本機離線計算 · 官方 API 等效價值 · 零額度消耗")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func formatCostMatrix(_ cost: Double) -> String {
        if cost >= 1_000_000 {
            return String(format: "$%.2fM", cost / 1_000_000)
        } else if cost >= 100_000 {
            return String(format: "$%.1fK", cost / 1_000)
        } else {
            return String(format: "$%.2f", cost)
        }
    }

    private func formatNTD(_ ntd: Double) -> String {
        let n = Int(ntd.rounded())
        if n >= 10_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private func formatCostCompact(_ cost: Double) -> String {
        if cost >= 1_000_000 {
            return String(format: "$%.2fM", cost / 1_000_000)
        } else if cost >= 1_000 {
            return String(format: "$%.2fK", cost / 1_000)
        } else {
            return String(format: "$%.2f", cost)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            return String(format: "%.2fB", Double(n) / 1_000_000_000)
        } else if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.0fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func copyMarkdownTable() {
        let stats = currentStats
        let title = selectedFilter.title
        var md = """
        ### 📊 UsageView 額度使用統計表 (\(title))
        | 統計期間 | Token 用量 | 估算花費 (USD) | 換算台幣 (約值) |
        | :--- | :--- | :--- | :--- |
        | ☀️ **當日 (Today)** | \(formatTokens(stats.todayTok)) tok (\(stats.todayTok)) | $\(String(format: "%.2f", stats.todayCost)) | NT$\(Int((stats.todayCost * 32.2).rounded())) |
        | 📅 **本週 (7D)** | \(formatTokens(stats.weekTok)) tok (\(stats.weekTok)) | $\(String(format: "%.2f", stats.weekCost)) | NT$\(Int((stats.weekCost * 32.2).rounded())) |
        | 🗓️ **本月 (30D)** | \(formatTokens(stats.monthTok)) tok (\(stats.monthTok)) | $\(String(format: "%.2f", stats.monthCost)) | NT$\(Int((stats.monthCost * 32.2).rounded())) |

        """

        if !stats.models.isEmpty {
            md += "\n#### 模型細項 (本月)\n"
            md += "| 模型 | 當日花費 | 本週花費 | 本月花費 | 本月 Token |\n"
            md += "| :--- | :--- | :--- | :--- | :--- |\n"
            for m in stats.models {
                md += "| \(m.vendor.map { "\(OpenCodeVendor.displayName($0)) · " } ?? "")\(m.model) | $\(String(format: "%.2f", m.todayCostUSD)) | $\(String(format: "%.2f", m.weekCostUSD)) | $\(String(format: "%.2f", m.monthCostUSD)) | \(formatTokens(m.monthTokens)) |\n"
            }
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) { copiedToast = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.2)) { copiedToast = false }
        }
    }
}
