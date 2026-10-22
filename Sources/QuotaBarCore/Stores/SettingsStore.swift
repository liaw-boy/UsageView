import Combine
import Foundation

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
    /// 狀態列是否自動只顯示已勾選中最緊張（5h 用量最高）的那一家
    @Published public var menuBarOnlyTightest: Bool {
        didSet { defaults.set(menuBarOnlyTightest, forKey: "menuBarOnlyTightest") }
    }

    public static let refreshOptions = [2, 5, 10, 15, 30]
    public static let minimumRefreshMinutes = 2

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let m = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = max(m == 0 ? 5 : m, Self.minimumRefreshMinutes)
        showRemaining = defaults.bool(forKey: "showRemaining")
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        menuBarOnlyTightest = defaults.bool(forKey: "menuBarOnlyTightest")

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
    }
}
