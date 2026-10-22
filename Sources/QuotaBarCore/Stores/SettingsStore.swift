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

    public static let refreshOptions = [2, 5, 10, 15, 30]
    public static let minimumRefreshMinutes = 2

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let m = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = max(m == 0 ? 5 : m, Self.minimumRefreshMinutes)
        showRemaining = defaults.bool(forKey: "showRemaining")
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true

        menuBarDisplayMode = MultiProviderDisplayMode(rawValue: defaults.string(forKey: "menuBarDisplayMode") ?? "") ?? .all
        menuBarMetricMode = MenuBarMetricMode(rawValue: defaults.string(forKey: "menuBarMetricMode") ?? "") ?? .sessionAndWeekly
        menuBarIconStyle = MenuBarIconStyle(rawValue: defaults.string(forKey: "menuBarIconStyle") ?? "") ?? .logo
        panelDisplayMode = MultiProviderDisplayMode(rawValue: defaults.string(forKey: "panelDisplayMode") ?? "") ?? .all
        selectedSingleProvider = ProviderID(rawValue: defaults.string(forKey: "selectedSingleProvider") ?? "") ?? .claude
        let cs = defaults.integer(forKey: "carouselSeconds")
        carouselSeconds = cs > 0 ? cs : 4

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

        if let saved = defaults.stringArray(forKey: "menuBarProviders") {
            menuBarProviders = Set(saved.compactMap(ProviderID.init))
        } else {
            menuBarProviders = initialTracked
        }
    }

    // MARK: - Queries

    public func isTracked(_ id: ProviderID) -> Bool { trackedProviders.contains(id) }
    public func isShownInPanel(_ id: ProviderID) -> Bool { isTracked(id) && panelProviders.contains(id) }
    public func isShownInMenuBar(_ id: ProviderID) -> Bool { isTracked(id) && menuBarProviders.contains(id) }

    /// Providers eligible for the "單一顯示" selector in Settings (only tracked providers enabled in the menu bar).
    public var availableMenuBarProviders: [ProviderID] {
        let inBar = ProviderID.allCases.filter { isShownInMenuBar($0) }
        if !inBar.isEmpty { return inBar }
        return ProviderID.allCases.filter { isTracked($0) }
    }

    // MARK: - Mutations with smart cascade

    public func setTracked(_ id: ProviderID, _ on: Bool) {
        if on {
            trackedProviders.insert(id)
            panelProviders.insert(id)
            menuBarProviders.insert(id)
        } else {
            trackedProviders.remove(id)
            panelProviders.remove(id)
            menuBarProviders.remove(id)
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

    private func syncSelectedSingleProvider() {
        let valid = availableMenuBarProviders
        if !valid.contains(selectedSingleProvider), let first = valid.first {
            selectedSingleProvider = first
        }
    }
}
