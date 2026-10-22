import AppKit
import Combine
import QuotaBarCore
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer!

    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--export-docs-images"), idx + 1 < args.count {
            DocsImageExporter.export(to: args[idx + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Close any stray default windows if macOS restored state
        for window in NSApp.windows {
            window.close()
        }
        container = AppContainer()
    }
}

/// Composition root (OpenUsage style): wires SettingsStore, SnapshotStore, UpdateService, notifications, and StatusItemController.
@MainActor
final class AppContainer {
    let settings = SettingsStore()
    let store: SnapshotStore
    let updater = UpdateService()
    let notifier: QuotaNotifier
    let statusItem: StatusItemController
    private var cancellable: AnyCancellable?

    init() {
        store = SnapshotStore(settings: settings)
        notifier = QuotaNotifier(store: store, settings: settings)
        statusItem = StatusItemController(store: store, settings: settings, updater: updater)
        // Only fetches providers that have no cached snapshot or whose persisted `fetchedAt` has exceeded `refreshMinutes`.
        // Restarting the app never re-fetches fresh cached providers!
        Task { await store.refresh(manual: false) }
        // Automatically check GitHub for new releases on launch.
        Task { await updater.checkForUpdates() }

        // When the user enables tracking for a provider that has no recent snapshot, check if due.
        cancellable = settings.$trackedProviders
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { await self?.store.refresh(manual: false) }
            }
    }
}

/// Threshold notifications: alerts once per reset window when crossing 80% or 95%.
@MainActor
final class QuotaNotifier {
    private var fired = Set<String>()
    private var cancellable: AnyCancellable?

    init(store: SnapshotStore, settings: SettingsStore) {
        cancellable = store.$states.sink { [weak self] states in
            guard settings.notificationsEnabled else { return }
            self?.evaluate(states)
        }
    }

    private func evaluate(_ states: [ProviderID: ProviderState]) {
        for (id, state) in states {
            guard let snap = state.snapshot else { continue }
            for line in snap.lines {
                for threshold in [95.0, 80.0] where line.usedPercent >= threshold {
                    let resetKey = line.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
                    let key = "\(id.rawValue):\(line.id):\(Int(threshold)):\(resetKey)"
                    guard !fired.contains(key) else { break }
                    fired.insert(key)
                    send(title: "\(id.displayName) 額度提醒",
                         body: "\(line.label) 已使用 \(Int(line.usedPercent.rounded()))%（超過 \(Int(threshold))%）")
                    break
                }
            }
        }
    }

    private func send(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Ignored when running unbundled via `swift run`.
        }
    }
}

@MainActor
enum DocsImageExporter {
    static func export(to directory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "docs-preview-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.showRemaining = true
        settings.menuBarDisplayMode = .single
        settings.menuBarMetricMode = .sessionAndWeekly
        settings.menuBarIconStyle = .logo

        let tmpCache = fm.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString).json")
        let store = SnapshotStore(settings: settings, cacheURL: tmpCache)
        store.populateShowcaseData()
        let updater = UpdateService()
        let controller = StatusItemController(store: store, settings: settings, updater: updater)

        // 1. Main Dashboard Preview
        controller.showingSettings = false
        let dashboard = DashboardView(store: store, settings: settings, updater: updater, controller: controller)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .padding(12)
            .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        save(dashboard, to: "\(directory)/dashboard-preview.png")

        // 2. Settings Preview
        controller.showingSettings = true
        let settingsView = DashboardView(store: store, settings: settings, updater: updater, controller: controller)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .padding(12)
            .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        save(settingsView, to: "\(directory)/settings-preview.png")

        // 3. Menu Bar Modes Comparison Banner
        let banner = MenuBarShowcaseBanner(store: store)
        save(banner, to: "\(directory)/menubar-modes.png")
    }

    private static func save<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

private struct MenuBarShowcaseBanner: View {
    let store: SnapshotStore

    private func makeSettings(mode: MultiProviderDisplayMode, metric: MenuBarMetricMode, icon: MenuBarIconStyle, single: ProviderID = .claude) -> SettingsStore {
        let s = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.showRemaining = true
        s.menuBarDisplayMode = mode
        s.menuBarMetricMode = metric
        s.menuBarIconStyle = icon
        s.selectedSingleProvider = single
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                showcaseTile(
                    title: "① 品牌圖示 · 雙行 (5h + 7d)",
                    subtitle: "預設模式 · 清楚標示 5h 與 7d 剩餘 %",
                    settings: makeSettings(mode: .single, metric: .sessionAndWeekly, icon: .logo, single: .claude)
                )
                showcaseTile(
                    title: "② 品牌圖示 · 單行 (僅 5 小時)",
                    subtitle: "極簡模式 · 固定寬度輪播不跳動",
                    settings: makeSettings(mode: .single, metric: .sessionOnly, icon: .logo, single: .claude)
                )
            }
            HStack(spacing: 12) {
                showcaseTile(
                    title: "③ 進度圓環模式",
                    subtitle: "高對比圓環搭配中心品牌色點",
                    settings: makeSettings(mode: .single, metric: .sessionAndWeekly, icon: .ring, single: .codex)
                )
                showcaseTile(
                    title: "④ 動態顏色警示（重置 <1h / 快耗盡）",
                    subtitle: "平常白色 · 剩 1h 內品牌色 · 快耗盡黃/紅",
                    settings: makeSettings(mode: .single, metric: .sessionAndWeekly, icon: .logo, single: .antigravity)
                )
            }
        }
        .padding(14)
        .background(Color(red: 0.145, green: 0.153, blue: 0.173))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .padding(10)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        .environment(\.colorScheme, .dark)
    }

    private func showcaseTile(title: String, subtitle: String, settings: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
            HStack {
                Spacer()
                MenuBarStripView(store: store, settings: settings)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(Color(red: 0.188, green: 0.196, blue: 0.220), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }
}
