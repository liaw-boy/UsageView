import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex, antigravity, opencode
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .antigravity: "A"
        case .opencode: "O"
        }
    }
}

public enum WindowKind: String, Codable, Sendable {
    case session, weekly
}

/// One normalized usage meter (OpenUsage's "MetricLine" idea): every provider maps into this shape.
public struct MetricLine: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let kind: WindowKind
    /// Optional pool name (Antigravity: "gemini" / "3p").
    public let pool: String?
    /// 0...100
    public let usedPercent: Double
    public let resetsAt: Date?
    public let periodSeconds: TimeInterval

    public init(id: String, label: String, kind: WindowKind, pool: String? = nil,
                usedPercent: Double, resetsAt: Date?, periodSeconds: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.pool = pool
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.periodSeconds = periodSeconds ?? (kind == .session ? 5 * 3600 : 7 * 86400)
    }

    /// Remaining quota percentage (0...100).
    public var remainingPercent: Double {
        max(0, 100.0 - usedPercent)
    }

    /// A rolling window with no usage yet (for Antigravity 5H pools, 0% used means "Quota available").
    public var isNotStarted: Bool {
        guard usedPercent == 0, kind == .session else { return false }
        return resetsAt == nil || pool != nil
    }

    public var pace: Pace? { Pace.evaluate(usedPercent: usedPercent, resetsAt: resetsAt, periodSeconds: periodSeconds) }

    /// Fraction (0...1) of the current window's time period that has already elapsed.
    /// Used to draw the "even-pace time tick" on the progress bar when `usedPercent > 0`.
    public func timeElapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, usedPercent > 0, periodSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = 1.0 - (remaining / periodSeconds)
        guard elapsed >= 0.02, elapsed <= 0.99 else { return nil }
        return min(max(elapsed, 0), 1)
    }

    /// Burn-rate projection text: estimates spare percentage at reset or time until exhaustion.
    public func projectionText(now: Date = Date()) -> (text: String, isWarning: Bool)? {
        guard let resetsAt, usedPercent > 0, periodSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 60 else { return nil }
        let elapsed = 1.0 - (remaining / periodSeconds)
        guard elapsed >= 0.05, elapsed < 1.0 else { return nil }

        let projectedTotal = usedPercent / elapsed
        if projectedTotal >= 100 {
            let elapsedSeconds = elapsed * periodSeconds
            let ratePerSecond = usedPercent / max(elapsedSeconds, 1)
            let secsLeft = max(60, Int(((100.0 - usedPercent) / ratePerSecond).rounded()))
            let h = secsLeft / 3600
            let m = (secsLeft % 3600) / 60
            let dur = h >= 24 ? "\(h / 24)d \(h % 24)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
            return ("~\(dur) 後耗盡", true)
        } else {
            let spare = max(0, Int((100.0 - projectedTotal).rounded()))
            return ("預計剩 ~\(spare)%", false)
        }
    }
}

/// Summary of local token usage and estimated API-equivalent USD value over Today, the last 7 days (Week), and 30 days (Month).
public struct ModelSpendBreakdown: Codable, Sendable, Equatable, Identifiable {
    public var id: String { (vendor ?? "") + "|" + model }
    public let model: String
    /// Which company's API served it (OpenCode only; raw `providerID`, e.g. "anthropic").
    public let vendor: String?
    public let todayCostUSD: Double
    public let todayTokens: Int
    public let weekCostUSD: Double
    public let weekTokens: Int
    public let monthCostUSD: Double
    public let monthTokens: Int

    public init(
        model: String,
        vendor: String? = nil,
        todayCostUSD: Double = 0,
        todayTokens: Int = 0,
        weekCostUSD: Double = 0,
        weekTokens: Int = 0,
        monthCostUSD: Double = 0,
        monthTokens: Int = 0
    ) {
        self.model = model
        self.vendor = vendor
        self.todayCostUSD = todayCostUSD
        self.todayTokens = todayTokens
        self.weekCostUSD = weekCostUSD
        self.weekTokens = weekTokens
        self.monthCostUSD = monthCostUSD
        self.monthTokens = monthTokens
    }
}

public struct DailyUsageItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { date }
    public let date: String // "yyyy-MM-dd"
    public let tokens: Int
    public let costUSD: Double

    public init(date: String, tokens: Int, costUSD: Double) {
        self.date = date
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct LocalSpendSummary: Codable, Sendable, Equatable {
    public let todayCostUSD: Double
    public let todayTokens: Int
    public let weekCostUSD: Double
    public let weekTokens: Int
    public let monthCostUSD: Double
    public let monthTokens: Int
    public let models: [ModelSpendBreakdown]
    public let dailyHistory: [DailyUsageItem]

    public init(
        todayCostUSD: Double,
        todayTokens: Int,
        weekCostUSD: Double = 0,
        weekTokens: Int = 0,
        monthCostUSD: Double,
        monthTokens: Int,
        models: [ModelSpendBreakdown] = [],
        dailyHistory: [DailyUsageItem] = []
    ) {
        self.todayCostUSD = todayCostUSD
        self.todayTokens = todayTokens
        self.weekCostUSD = weekCostUSD
        self.weekTokens = weekTokens
        self.monthCostUSD = monthCostUSD
        self.monthTokens = monthTokens
        self.models = models
        self.dailyHistory = dailyHistory
    }

    public enum CodingKeys: String, CodingKey {
        case todayCostUSD, todayTokens, weekCostUSD, weekTokens, monthCostUSD, monthTokens, models, dailyHistory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let todayCost = try c.decode(Double.self, forKey: .todayCostUSD)
        let todayTok = try c.decode(Int.self, forKey: .todayTokens)
        let monthCost = try c.decode(Double.self, forKey: .monthCostUSD)
        let monthTok = try c.decode(Int.self, forKey: .monthTokens)
        self.todayCostUSD = todayCost
        self.todayTokens = todayTok
        self.monthCostUSD = monthCost
        self.monthTokens = monthTok
        self.weekCostUSD = try c.decodeIfPresent(Double.self, forKey: .weekCostUSD) ?? todayCost
        self.weekTokens = try c.decodeIfPresent(Int.self, forKey: .weekTokens) ?? todayTok
        self.models = try c.decodeIfPresent([ModelSpendBreakdown].self, forKey: .models) ?? []
        self.dailyHistory = try c.decodeIfPresent([DailyUsageItem].self, forKey: .dailyHistory) ?? []
    }

    public var hasAnyUsage: Bool {
        todayTokens > 0 || weekTokens > 0 || monthTokens > 0 || todayCostUSD > 0 || weekCostUSD > 0 || monthCostUSD > 0
    }
}

/// Rolling-window spend in USD for providers without a quota percentage (OpenCode without a budget).
public struct WindowSpend: Codable, Sendable, Equatable {
    public let sessionUSD: Double
    public let weeklyUSD: Double

    public init(sessionUSD: Double, weeklyUSD: Double) {
        self.sessionUSD = sessionUSD
        self.weeklyUSD = weeklyUSD
    }
}

public struct ProviderSnapshot: Codable, Sendable, Equatable {
    public let provider: ProviderID
    public let lines: [MetricLine]
    public let fetchedAt: Date
    public var planName: String?
    public var extraUsageText: String?
    public var localSpend: LocalSpendSummary?
    public var windowSpend: WindowSpend?

    public init(
        provider: ProviderID,
        lines: [MetricLine],
        fetchedAt: Date = Date(),
        planName: String? = nil,
        extraUsageText: String? = nil,
        localSpend: LocalSpendSummary? = nil,
        windowSpend: WindowSpend? = nil
    ) {
        self.provider = provider
        self.lines = lines
        self.fetchedAt = fetchedAt
        self.planName = planName
        self.extraUsageText = extraUsageText
        self.localSpend = localSpend
        self.windowSpend = windowSpend
    }

    /// Primary session usage — for Antigravity, always prefers its native Gemini pool (`pool == "gemini"`)
    /// rather than the third-party Claude/GPT pool (`pool == "3p"`).
    public var sessionPercent: Double? {
        if provider == .antigravity,
           let gemini = lines.first(where: { $0.kind == .session && $0.pool == "gemini" }) {
            return gemini.usedPercent
        }
        return lines.filter { $0.kind == .session }.map(\.usedPercent).max()
    }

    /// Primary weekly usage — for Antigravity, always prefers its native Gemini weekly pool (`id == "gemini-weekly"`).
    public var weeklyPercent: Double? {
        if provider == .antigravity {
            if let geminiWeekly = lines.first(where: { $0.id == "gemini-weekly" })
                ?? lines.first(where: { $0.kind == .weekly && $0.pool == "gemini" }) {
                return geminiWeekly.usedPercent
            }
        }
        return lines.filter { $0.kind == .weekly }.map(\.usedPercent).max()
    }

    /// True when the primary window of `kind` has less than or equal to 1 hour (3600s) remaining before reset.
    public func isResettingWithinOneHour(kind: WindowKind, now: Date = Date()) -> Bool {
        let targetLines: [MetricLine]
        if provider == .antigravity {
            let geminiLines = lines.filter { $0.kind == kind && $0.pool == "gemini" }
            targetLines = geminiLines.isEmpty ? lines.filter { $0.kind == kind } : geminiLines
        } else {
            targetLines = lines.filter { $0.kind == kind }
        }
        return targetLines.contains { line in
            guard let reset = line.resetsAt else { return false }
            let remaining = reset.timeIntervalSince(now)
            return remaining > 0 && remaining <= 3600
        }
    }
}

/// Burn-rate estimate: are we using the window faster than time is passing?
public enum Pace: String, Sendable, CaseIterable {
    case useFaster   // 快一點用（時間過得比額度消耗快很多，不用白不用）
    case comfortable // 放心用（配速剛剛好）
    case slowDown    // 少用一點（消耗速度偏快）
    case conserve    // 省著點用（額度吃緊或消耗太快）
    case almostGone  // 要沒了！（額度即將見底）

    public static func evaluate(usedPercent: Double, resetsAt: Date?, periodSeconds: TimeInterval, now: Date = Date()) -> Pace? {
        if usedPercent >= 92 { return .almostGone }
        if usedPercent >= 82 { return .conserve }
        guard let resetsAt, usedPercent > 0, periodSeconds > 0 else {
            if usedPercent >= 70 { return .slowDown }
            return nil
        }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = 1 - remaining / periodSeconds
        guard elapsed >= 0.05, elapsed <= 1 else {
            if usedPercent >= 70 { return .slowDown }
            return nil
        }
        let ratio = usedPercent / (elapsed * 100)
        if ratio < 0.65 { return .useFaster }
        if ratio <= 1.10 { return .comfortable }
        if ratio <= 1.45 { return .slowDown }
        return .conserve
    }
}
