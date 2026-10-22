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
public enum Pace: String, Sendable {
    case relaxed, onTrack, fast

    public static func evaluate(usedPercent: Double, resetsAt: Date?, periodSeconds: TimeInterval, now: Date = Date()) -> Pace? {
        guard let resetsAt, usedPercent > 0, periodSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = 1 - remaining / periodSeconds
        guard elapsed >= 0.05, elapsed <= 1 else { return nil } // too early to judge
        let ratio = usedPercent / (elapsed * 100)
        if ratio < 0.8 { return .relaxed }
        if ratio <= 1.15 { return .onTrack }
        return .fast
    }
}
