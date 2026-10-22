import Combine
import Foundation

public enum MenuBarMode: String, CaseIterable, Codable, Sendable {
    case all, tightest, iconOnly
    public var title: String {
        switch self {
        case .all: "全部顯示"
        case .tightest: "只顯示最緊張的一家"
        case .iconOnly: "只顯示圖示"
        }
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published public var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published public var showRemaining: Bool { didSet { defaults.set(showRemaining, forKey: "showRemaining") } }
    @Published public var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notifications") } }
    @Published public var disabledProviders: Set<ProviderID> {
        didSet { defaults.set(disabledProviders.map(\.rawValue), forKey: "disabledProviders") }
    }

    public static let refreshOptions = [2, 5, 10, 15, 30]
    public static let minimumRefreshMinutes = 2

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let m = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = max(m == 0 ? 5 : m, Self.minimumRefreshMinutes)
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .all
        showRemaining = defaults.bool(forKey: "showRemaining")
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        disabledProviders = Set((defaults.stringArray(forKey: "disabledProviders") ?? []).compactMap(ProviderID.init))
    }

    public func isEnabled(_ id: ProviderID) -> Bool { !disabledProviders.contains(id) }

    public func setEnabled(_ id: ProviderID, _ on: Bool) {
        if on { disabledProviders.remove(id) } else { disabledProviders.insert(id) }
    }
}
