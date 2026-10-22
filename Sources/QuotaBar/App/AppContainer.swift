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
        Task { await store.refresh() }

        // When the user enables tracking for a provider in Settings, refresh immediately.
        cancellable = settings.$trackedProviders
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { await self?.store.refresh() }
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
