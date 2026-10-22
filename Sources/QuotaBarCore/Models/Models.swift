import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex, antigravity
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .antigravity: "A"
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

    /// A rolling window with no usage and no reset scheduled yet.
    public var isNotStarted: Bool { usedPercent == 0 && resetsAt == nil && kind == .session }

    public var pace: Pace? { Pace.evaluate(usedPercent: usedPercent, resetsAt: resetsAt, periodSeconds: periodSeconds) }
}

public struct ProviderSnapshot: Codable, Sendable, Equatable {
    public let provider: ProviderID
    public let lines: [MetricLine]
    public let fetchedAt: Date

    public init(provider: ProviderID, lines: [MetricLine], fetchedAt: Date = Date()) {
        self.provider = provider
        self.lines = lines
        self.fetchedAt = fetchedAt
    }

    /// Highest session usage — the headline number.
    public var sessionPercent: Double? {
        lines.filter { $0.kind == .session }.map(\.usedPercent).max()
    }

    public var weeklyPercent: Double? {
        lines.filter { $0.kind == .weekly }.map(\.usedPercent).max()
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
