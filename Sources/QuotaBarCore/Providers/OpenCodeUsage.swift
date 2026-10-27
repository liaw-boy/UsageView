import Foundation
import SQLite3

/// How OpenCode usage is turned into quota meters. OpenCode has no quota API, so everything is derived from
/// the local `opencode.db` (offline, read-only); percentages only exist when a budget is configured.
public enum OpenCodeQuotaMode: String, CaseIterable, Codable, Sendable {
    case spendOnly // 只顯示花費
    case go        // OpenCode Go ($10/月)
    case goPlus    // OpenCode Go Plus ($40/月)
    case custom    // 自訂預算

    public var title: String {
        switch self {
        case .spendOnly: "只看花費"
        case .go: "Go"
        case .goPlus: "Go Plus"
        case .custom: "自訂"
        }
    }

    /// Whether only `opencode-go` spend counts toward the budget (otherwise every provider counts).
    var goOnly: Bool { self == .go || self == .goPlus }
}

public struct OpenCodeQuotaConfig: Sendable, Equatable {
    public var mode: OpenCodeQuotaMode
    public var customSessionBudget: Double
    public var customWeeklyBudget: Double

    public init(mode: OpenCodeQuotaMode = .spendOnly, customSessionBudget: Double = 5, customWeeklyBudget: Double = 20) {
        self.mode = mode
        self.customSessionBudget = customSessionBudget
        self.customWeeklyBudget = customWeeklyBudget
    }

    /// (5-hour, weekly) USD budgets, or nil when no percentages should be shown.
    var budgets: (session: Double, weekly: Double)? {
        switch mode {
        case .spendOnly: nil
        case .go: (12, 30)
        case .goPlus: (48, 120)
        case .custom:
            customSessionBudget > 0 && customWeeklyBudget > 0 ? (customSessionBudget, customWeeklyBudget) : nil
        }
    }

    public static let modeKey = "opencodeQuotaMode"
    public static let sessionKey = "opencodeSessionBudget"
    public static let weeklyKey = "opencodeWeeklyBudget"

    public static func load(from defaults: UserDefaults = .standard) -> OpenCodeQuotaConfig {
        let s = defaults.double(forKey: sessionKey)
        let w = defaults.double(forKey: weeklyKey)
        return OpenCodeQuotaConfig(
            mode: OpenCodeQuotaMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .spendOnly,
            customSessionBudget: s > 0 ? s : 5,
            customWeeklyBudget: w > 0 ? w : 20
        )
    }
}

/// One finished assistant response recorded by OpenCode.
public struct OpenCodeUsageRecord: Sendable, Equatable {
    public let timestamp: Date
    public let providerID: String
    public let modelID: String
    public let costUSD: Double
    public let tokens: Int

    public init(timestamp: Date, providerID: String, modelID: String, costUSD: Double, tokens: Int) {
        self.timestamp = timestamp
        self.providerID = providerID
        self.modelID = modelID
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

/// Reads `~/.local/share/opencode/opencode.db` strictly read-only. Never touches the `credential` / `account`
/// tables and never opens a network connection, so it cannot consume any API quota.
public enum OpenCodeDatabase {
    public static func defaultPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let base = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/.local/share")
        return base + "/opencode/opencode.db"
    }

    public static func exists(at path: String = defaultPath()) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Returns nil when the database is missing or its schema is not the expected one.
    public static func records(at path: String = defaultPath(), since: Date) -> [OpenCodeUsageRecord]? {
        guard exists(at: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)

        let sql = """
        SELECT time_created,
               json_extract(data, '$.model.providerID'),
               json_extract(data, '$.model.id'),
               json_extract(data, '$.cost'),
               COALESCE(json_extract(data, '$.tokens.input'), 0)
                 + COALESCE(json_extract(data, '$.tokens.output'), 0)
                 + COALESCE(json_extract(data, '$.tokens.reasoning'), 0)
                 + COALESCE(json_extract(data, '$.tokens.cache.read'), 0)
                 + COALESCE(json_extract(data, '$.tokens.cache.write'), 0)
        FROM session_message
        WHERE type = 'assistant' AND time_created >= ?1
          AND json_extract(data, '$.cost') IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))

        var out: [OpenCodeUsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ms = sqlite3_column_double(stmt, 0)
            func text(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            out.append(OpenCodeUsageRecord(
                timestamp: Date(timeIntervalSince1970: ms / 1000),
                providerID: text(1),
                modelID: text(2),
                costUSD: sqlite3_column_double(stmt, 3),
                tokens: Int(sqlite3_column_int64(stmt, 4))
            ))
        }
        return out
    }
}

enum OpenCodeMapper {
    static let sessionWindow: TimeInterval = 5 * 3600
    static let weeklyWindow: TimeInterval = 7 * 86400

    /// Rolling-window meters. Empty in spend-only mode (no budget means no percentage).
    static func map(_ records: [OpenCodeUsageRecord], config: OpenCodeQuotaConfig, now: Date = Date()) -> [MetricLine] {
        guard let budgets = config.budgets else { return [] }
        let counted = config.mode.goOnly ? records.filter { $0.providerID == "opencode-go" } : records

        func line(id: String, label: String, kind: WindowKind, window: TimeInterval, budget: Double) -> MetricLine {
            let inWindow = counted.filter { $0.timestamp > now.addingTimeInterval(-window) && $0.timestamp <= now }
            let spent = inWindow.reduce(0) { $0 + $1.costUSD }
            // The server's real reset moment is unknown; estimate it from the oldest charge still in the window.
            let resets = inWindow.map(\.timestamp).min().map { $0.addingTimeInterval(window) }
            return MetricLine(id: id, label: label, kind: kind, usedPercent: spent / budget * 100,
                              resetsAt: resets, periodSeconds: window)
        }
        return [
            line(id: "5h", label: "5H", kind: .session, window: sessionWindow, budget: budgets.session),
            line(id: "7d", label: "7D", kind: .weekly, window: weeklyWindow, budget: budgets.weekly),
        ]
    }

    /// Spend over the same rolling windows, across every provider (shown when there is no budget to turn into a percentage).
    static func windowSpend(_ records: [OpenCodeUsageRecord], now: Date = Date()) -> WindowSpend {
        func spent(_ window: TimeInterval) -> Double {
            records.filter { $0.timestamp > now.addingTimeInterval(-window) && $0.timestamp <= now }.reduce(0) { $0 + $1.costUSD }
        }
        return WindowSpend(sessionUSD: spent(sessionWindow), weeklyUSD: spent(weeklyWindow))
    }

    static func planName(_ config: OpenCodeQuotaConfig) -> String? {
        switch config.mode {
        case .spendOnly: "本機花費"
        case .go: "Go · 估算"
        case .goPlus: "Go Plus · 估算"
        case .custom: "自訂預算"
        }
    }
}

struct OpenCodeRuntime: ProviderRuntime {
    let id = ProviderID.opencode
    let databasePath: String
    let config: @Sendable () -> OpenCodeQuotaConfig

    init(databasePath: String = OpenCodeDatabase.defaultPath(),
         config: @escaping @Sendable () -> OpenCodeQuotaConfig = { OpenCodeQuotaConfig.load() }) {
        self.databasePath = databasePath
        self.config = config
    }

    func fetch() async throws -> [MetricLine] {
        try await fetchResult().lines
    }

    func fetchResult() async throws -> ProviderFetchResult {
        guard OpenCodeDatabase.exists(at: databasePath) else {
            throw ProviderError.notLoggedIn("找不到 OpenCode 資料庫，請先使用過一次 opencode")
        }
        let now = Date()
        guard let records = OpenCodeDatabase.records(at: databasePath, since: now.addingTimeInterval(-OpenCodeMapper.weeklyWindow)) else {
            throw ProviderError.parse
        }
        let cfg = config()
        return ProviderFetchResult(lines: OpenCodeMapper.map(records, config: cfg, now: now),
                                   planName: OpenCodeMapper.planName(cfg),
                                   windowSpend: OpenCodeMapper.windowSpend(records, now: now))
    }
}

/// Maps OpenCode's raw `providerID` to a readable company name, and to one of our existing brand marks when we have one.
public enum OpenCodeVendor {
    public static func displayName(_ providerID: String) -> String {
        switch providerID.lowercased() {
        case "anthropic": "Anthropic"
        case "openai": "OpenAI"
        case "google", "google-vertex": "Google"
        case "opencode-go": "OpenCode Go"
        case "opencode": "OpenCode Zen"
        case "openrouter": "OpenRouter"
        case "github-copilot": "GitHub Copilot"
        case "xai": "xAI"
        case "deepseek": "DeepSeek"
        default: providerID.prefix(1).uppercased() + providerID.dropFirst()
        }
    }

    /// The in-app provider whose logo represents this vendor (nil = no logo, a text badge is used instead).
    public static func logoProvider(_ providerID: String) -> ProviderID? {
        switch providerID.lowercased() {
        case "anthropic": .claude
        case "openai": .codex
        case "opencode", "opencode-go": .opencode
        default: nil
        }
    }
}
