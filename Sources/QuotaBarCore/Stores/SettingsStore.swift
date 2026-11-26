import Combine
import Foundation

/// How multiple enabled AI providers are presented in the Menu Bar or Dashboard Panel.
public enum MultiProviderDisplayMode: String, CaseIterable, Codable, Sendable {
    case all       // 全部並排
    case single    // 單一顯示
    case carousel  // 自動輪播

    public var title: String {
        switch self {
        case .all: "全部"
        case .single: "單一"
        case .carousel: "輪播"
        }
    }

    public var icon: String {
        switch self {
        case .all: "rectangle.grid.1x2.fill"
        case .single: "1.circle.fill"
        case .carousel: "arrow.triangle.2.circlepath"
        }
    }
}

/// Which quota windows are shown in the macOS menu bar item.
public enum MenuBarMetricMode: String, CaseIterable, Codable, Sendable {
    case sessionOnly      // 僅 5 小時
    case sessionAndWeekly // 5 小時 + 7 天

    public var title: String {
        switch self {
        case .sessionOnly: "僅 5 小時"
        case .sessionAndWeekly: "5 小時 + 7 天"
        }
    }
}

/// Leading indicator style in the macOS menu bar item.
public enum MenuBarIconStyle: String, CaseIterable, Codable, Sendable {
    case logo // 品牌圖示
    case ring // 進度圓環

    public var title: String {
        switch self {
        case .logo: "品牌圖示"
        case .ring: "進度圓環"
        }
    }
}

/// Visual layout for the always-on-top floating ball widget.
public enum FloatingBallStyle: String, CaseIterable, Codable, Sendable {
    case orb  // 精簡圓球（單一輪播）
    case pill // 膠囊條（並排顯示）

    public var title: String {
        switch self {
        case .orb: "圓球"
        case .pill: "膠囊"
        }
    }
}

/// Where a strip of provider readings is drawn; each surface has its own providers, mode, period and icon.
public enum StripTarget: Sendable { case menuBar, floatingBall }

public struct StripSettings: Equatable, Sendable {
    public let displayMode: MultiProviderDisplayMode
    public let metricMode: MenuBarMetricMode
    public let iconStyle: MenuBarIconStyle
    public let singleProvider: ProviderID
}

@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") }
    }
    @Published public var showRemaining: Bool {
        didSet { defaults.set(showRemaining, forKey: "showRemaining") }
    }
    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notifications") }
    }
    /// Read Claude limits from Claude Code's status line (installs `ClaudeStatusLineBridge`) instead of mostly polling the API.
    @Published public var claudeStatusLineBridge: Bool {
        didSet { defaults.set(claudeStatusLineBridge, forKey: "claudeStatusLineBridge") }
    }
    /// 1. 啟動哪些服務的追蹤（未勾選者完全不發送請求、不讀憑證）
    @Published public var trackedProviders: Set<ProviderID> {
        didSet { defaults.set(trackedProviders.map(\.rawValue), forKey: "trackedProviders") }
    }
    /// 2. 點開面板後，裡面要顯示哪些服務的卡片
    @Published public var panelProviders: Set<ProviderID> {
        didSet { defaults.set(panelProviders.map(\.rawValue), forKey: "panelProviders") }
    }
    /// 3. 狀態列上要顯示哪些服務的即時膠囊
    @Published public var menuBarProviders: Set<ProviderID> {
        didSet { defaults.set(menuBarProviders.map(\.rawValue), forKey: "menuBarProviders") }
    }
    /// 狀態列多 AI 顯示模式：全部 / 單一（最緊張） / 輪播
    @Published public var menuBarDisplayMode: MultiProviderDisplayMode {
        didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") }
    }
    /// 狀態列顯示週期：僅 5 小時 / 5 小時 + 7 天
    @Published public var menuBarMetricMode: MenuBarMetricMode {
        didSet { defaults.set(menuBarMetricMode.rawValue, forKey: "menuBarMetricMode") }
    }
    /// 狀態列左側圖示：品牌圖示（預設） / 進度圓環
    @Published public var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: "menuBarIconStyle") }
    }
    /// 展開面板多 AI 顯示模式：全部 / 單一（可切換） / 輪播
    @Published public var panelDisplayMode: MultiProviderDisplayMode {
        didSet { defaults.set(panelDisplayMode.rawValue, forKey: "panelDisplayMode") }
    }
    /// 單一模式下目前選中的 Provider
    @Published public var selectedSingleProvider: ProviderID {
        didSet { defaults.set(selectedSingleProvider.rawValue, forKey: "selectedSingleProvider") }
    }
    /// 輪播間隔秒數
    @Published public var carouselSeconds: Int {
        didSet { defaults.set(carouselSeconds, forKey: "carouselSeconds") }
    }

    /// OpenCode 沒有額度 API：預設只顯示本機花費，也可選 Go / Go Plus / 自訂預算換算百分比。
    @Published public var opencodeQuotaMode: OpenCodeQuotaMode {
        didSet { defaults.set(opencodeQuotaMode.rawValue, forKey: OpenCodeQuotaConfig.modeKey) }
    }
    @Published public var opencodeSessionBudget: Double {
        didSet { defaults.set(opencodeSessionBudget, forKey: OpenCodeQuotaConfig.sessionKey) }
    }
    @Published public var opencodeWeeklyBudget: Double {
        didSet { defaults.set(opencodeWeeklyBudget, forKey: OpenCodeQuotaConfig.weeklyKey) }
    }

    /// 「釋放空間」一鍵清理條件：最後更新超過 N 天，且單筆對話至少 N MB。
    @Published public var cleanupMinAgeDays: Int {
        didSet { defaults.set(cleanupMinAgeDays, forKey: "cleanupMinAgeDays") }
    }
    @Published public var cleanupMinSizeMB: Int {
        didSet { defaults.set(cleanupMinSizeMB, forKey: "cleanupMinSizeMB") }
    }

    /// Menu bar icon and floating ball are independent, but at least one stays on: the app has no Dock icon,
    /// so with both off there would be no way back into it.
    @Published public var menuBarIconEnabled: Bool {
        didSet {
            defaults.set(menuBarIconEnabled, forKey: "menuBarIconEnabled")
            if !menuBarIconEnabled && !floatingBallEnabled { floatingBallEnabled = true }
        }
    }
    @Published public var floatingBallEnabled: Bool {
        didSet {
            defaults.set(floatingBallEnabled, forKey: "floatingBallEnabled")
            if !floatingBallEnabled && !menuBarIconEnabled { menuBarIconEnabled = true }
        }
    }
    /// The floating ball's own copy of the menu bar display options (seeded from the menu bar on first launch).
    @Published public var floatingBallProviders: Set<ProviderID> {
        didSet { defaults.set(floatingBallProviders.map(\.rawValue), forKey: "floatingBallProviders") }
    }
    @Published public var floatingBallDisplayMode: MultiProviderDisplayMode {
        didSet { defaults.set(floatingBallDisplayMode.rawValue, forKey: "floatingBallDisplayMode") }
    }
    @Published public var floatingBallMetricMode: MenuBarMetricMode {
        didSet { defaults.set(floatingBallMetricMode.rawValue, forKey: "floatingBallMetricMode") }
    }
    @Published public var floatingBallIconStyle: MenuBarIconStyle {
        didSet { defaults.set(floatingBallIconStyle.rawValue, forKey: "floatingBallIconStyle") }
    }
    @Published public var floatingBallSingleProvider: ProviderID {
        didSet { defaults.set(floatingBallSingleProvider.rawValue, forKey: "floatingBallSingleProvider") }
    }
    @Published public var floatingBallStyle: FloatingBallStyle {
        didSet { defaults.set(floatingBallStyle.rawValue, forKey: "floatingBallStyle") }
    }
    @Published public var floatingBallOpacity: Double {
        didSet { defaults.set(floatingBallOpacity, forKey: "floatingBallOpacity") }
    }

    public static let floatingBallOpacityOptions: [Double] = [0.60, 0.80, 0.95]

    public func savedFloatingBallOrigin() -> CGPoint? {
        guard defaults.object(forKey: "floatingBallX") != nil,
              defaults.object(forKey: "floatingBallY") != nil
        else { return nil }
        return CGPoint(x: defaults.double(forKey: "floatingBallX"),
                       y: defaults.double(forKey: "floatingBallY"))
    }

    public func saveFloatingBallOrigin(_ origin: CGPoint) {
        defaults.set(Double(origin.x), forKey: "floatingBallX")
        defaults.set(Double(origin.y), forKey: "floatingBallY")
    }

    public static let cleanupAgeOptions = [7, 14, 30, 60, 90]
    public static let cleanupSizeOptions = [10, 50, 100, 500, 1000]

    public static let refreshOptions = [2, 5, 10, 15, 30]
    public static let minimumRefreshMinutes = 2

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let m = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = max(m == 0 ? 5 : m, Self.minimumRefreshMinutes)
        showRemaining = defaults.bool(forKey: "showRemaining")
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        claudeStatusLineBridge = defaults.object(forKey: "claudeStatusLineBridge") as? Bool ?? true

        let barMode = MultiProviderDisplayMode(rawValue: defaults.string(forKey: "menuBarDisplayMode") ?? "") ?? .all
        let barMetric = MenuBarMetricMode(rawValue: defaults.string(forKey: "menuBarMetricMode") ?? "") ?? .sessionAndWeekly
        let barIcon = MenuBarIconStyle(rawValue: defaults.string(forKey: "menuBarIconStyle") ?? "") ?? .logo
        let barSingle = ProviderID(rawValue: defaults.string(forKey: "selectedSingleProvider") ?? "") ?? .claude
        menuBarDisplayMode = barMode
        menuBarMetricMode = barMetric
        menuBarIconStyle = barIcon
        panelDisplayMode = MultiProviderDisplayMode(rawValue: defaults.string(forKey: "panelDisplayMode") ?? "") ?? .all
        selectedSingleProvider = barSingle
        floatingBallDisplayMode = MultiProviderDisplayMode(rawValue: defaults.string(forKey: "floatingBallDisplayMode") ?? "") ?? barMode
        floatingBallMetricMode = MenuBarMetricMode(rawValue: defaults.string(forKey: "floatingBallMetricMode") ?? "") ?? barMetric
        floatingBallIconStyle = MenuBarIconStyle(rawValue: defaults.string(forKey: "floatingBallIconStyle") ?? "") ?? barIcon
        floatingBallSingleProvider = ProviderID(rawValue: defaults.string(forKey: "floatingBallSingleProvider") ?? "") ?? barSingle
        let oc = OpenCodeQuotaConfig.load(from: defaults)
        opencodeQuotaMode = oc.mode
        opencodeSessionBudget = oc.customSessionBudget
        opencodeWeeklyBudget = oc.customWeeklyBudget
        let age = defaults.integer(forKey: "cleanupMinAgeDays")
        cleanupMinAgeDays = age == 0 ? 14 : min(max(age, 1), 365)
        let size = defaults.integer(forKey: "cleanupMinSizeMB")
        cleanupMinSizeMB = size == 0 ? 50 : min(max(size, 1), 5000)
        let cs = defaults.integer(forKey: "carouselSeconds")
        carouselSeconds = cs > 0 ? cs : 4

        let fbEnabled = defaults.bool(forKey: "floatingBallEnabled")
        floatingBallEnabled = fbEnabled
        floatingBallStyle = FloatingBallStyle(rawValue: defaults.string(forKey: "floatingBallStyle") ?? "") ?? .pill
        let rawOpacity = defaults.object(forKey: "floatingBallOpacity") as? Double ?? 0.95
        floatingBallOpacity = min(max(rawOpacity, 0.45), 1.0)
        // Migrates the old "hide the menu bar icon while the ball is shown" option.
        let iconOn = defaults.object(forKey: "menuBarIconEnabled") as? Bool
            ?? !(fbEnabled && defaults.bool(forKey: "hideMenuBarWhenFloating"))
        menuBarIconEnabled = iconOn || !fbEnabled

        let all = Set(ProviderID.allCases)
        let initialTracked: Set<ProviderID>
        if let saved = defaults.stringArray(forKey: "trackedProviders") {
            initialTracked = Set(saved.compactMap(ProviderID.init))
        } else if let legacyDisabled = defaults.stringArray(forKey: "disabledProviders") {
            initialTracked = all.subtracting(legacyDisabled.compactMap(ProviderID.init))
        } else {
            initialTracked = all
        }
        trackedProviders = initialTracked

        if let saved = defaults.stringArray(forKey: "panelProviders") {
            panelProviders = Set(saved.compactMap(ProviderID.init))
        } else {
            panelProviders = initialTracked
        }

        let barProviders = defaults.stringArray(forKey: "menuBarProviders").map { Set($0.compactMap(ProviderID.init)) }
            ?? initialTracked
        menuBarProviders = barProviders
        floatingBallProviders = defaults.stringArray(forKey: "floatingBallProviders").map { Set($0.compactMap(ProviderID.init)) }
            ?? barProviders
    }

    // MARK: - Queries

    public func isTracked(_ id: ProviderID) -> Bool { trackedProviders.contains(id) }
    public func isShownInPanel(_ id: ProviderID) -> Bool { isTracked(id) && panelProviders.contains(id) }
    public func isShownInMenuBar(_ id: ProviderID) -> Bool { isTracked(id) && menuBarProviders.contains(id) }
    public func isShownInFloatingBall(_ id: ProviderID) -> Bool { isTracked(id) && floatingBallProviders.contains(id) }

    public func isShown(_ id: ProviderID, on target: StripTarget) -> Bool {
        target == .menuBar ? isShownInMenuBar(id) : isShownInFloatingBall(id)
    }

    public func strip(_ target: StripTarget) -> StripSettings {
        switch target {
        case .menuBar:
            StripSettings(displayMode: menuBarDisplayMode, metricMode: menuBarMetricMode,
                          iconStyle: menuBarIconStyle, singleProvider: selectedSingleProvider)
        case .floatingBall:
            StripSettings(displayMode: floatingBallDisplayMode, metricMode: floatingBallMetricMode,
                          iconStyle: floatingBallIconStyle, singleProvider: floatingBallSingleProvider)
        }
    }

    /// Providers eligible for that surface's "單一顯示" selector.
    public func availableProviders(for target: StripTarget) -> [ProviderID] {
        let shown = ProviderID.allCases.filter { isShown($0, on: target) }
        return shown.isEmpty ? ProviderID.allCases.filter { isTracked($0) } : shown
    }

    /// Providers eligible for the "單一顯示" selector in Settings (only tracked providers enabled in the menu bar).
    public var availableMenuBarProviders: [ProviderID] { availableProviders(for: .menuBar) }

    // MARK: - Mutations with smart cascade

    public func setTracked(_ id: ProviderID, _ on: Bool) {
        if on {
            trackedProviders.insert(id)
            panelProviders.insert(id)
            menuBarProviders.insert(id)
            floatingBallProviders.insert(id)
        } else {
            trackedProviders.remove(id)
            panelProviders.remove(id)
            menuBarProviders.remove(id)
            floatingBallProviders.remove(id)
        }
        syncSelectedSingleProvider()
    }

    public func setShownInPanel(_ id: ProviderID, _ on: Bool) {
        if on {
            trackedProviders.insert(id)
            panelProviders.insert(id)
        } else {
            panelProviders.remove(id)
        }
    }

    public func setShownInMenuBar(_ id: ProviderID, _ on: Bool) {
        if on {
            trackedProviders.insert(id)
            menuBarProviders.insert(id)
        } else {
            menuBarProviders.remove(id)
        }
        syncSelectedSingleProvider()
    }

    public func setShownInFloatingBall(_ id: ProviderID, _ on: Bool) {
        if on {
            trackedProviders.insert(id)
            floatingBallProviders.insert(id)
        } else {
            floatingBallProviders.remove(id)
        }
        syncSelectedSingleProvider()
    }

    private func syncSelectedSingleProvider() {
        let valid = availableMenuBarProviders
        if !valid.contains(selectedSingleProvider), let first = valid.first {
            selectedSingleProvider = first
        }
        let ballValid = availableProviders(for: .floatingBall)
        if !ballValid.contains(floatingBallSingleProvider), let first = ballValid.first {
            floatingBallSingleProvider = first
        }
    }
}
