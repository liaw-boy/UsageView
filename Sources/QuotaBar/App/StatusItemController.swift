import AppKit
import Combine
import QuotaBarCore
import SwiftUI

/// AppKit status item + auto-sizing floating panel.
/// Left-click toggles the popover; right-click opens the quick context menu (Refresh / Check Updates / Settings / Quit).
@MainActor
final class StatusItemController: NSObject, ObservableObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: SnapshotStore
    private let settings: SettingsStore
    private let updater: UpdateService
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    @Published var showingSettings = false

    init(store: SnapshotStore, settings: SettingsStore, updater: UpdateService) {
        self.store = store
        self.settings = settings
        self.updater = updater
        super.init()

        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(
            rootView: DashboardView(store: store, settings: settings, updater: updater, controller: self)
        )
        // Auto-size popover height to hug the SwiftUI content with zero wasted top/bottom space!
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStrip()
                self?.syncPopoverSize()
            }
            .store(in: &cancellables)

        $showingSettings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncPopoverSize()
            }
            .store(in: &cancellables)

        // Also wake-refresh when the Mac wakes from sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh() }
        }

        updateStrip()
    }

    func syncPopoverSize() {
        guard let view = popover.contentViewController?.view else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize
            if fitting.height > 10 {
                self.popover.contentSize = NSSize(width: 356, height: fitting.height)
            }
        }
    }

    private func updateStrip() {
        guard let button = statusItem.button else { return }
        let view = MenuBarStripView(store: store, settings: settings)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        if let image = renderer.nsImage {
            image.isTemplate = false
            button.image = image
            button.title = ""
            // Lock exact status item length so carousel rotation or digit count changes never resize the button.
            statusItem.length = image.size.width
        } else {
            button.image = nil
            button.title = "◎ UsageView"
            statusItem.length = NSStatusItem.variableLength
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            stopMonitoringOutsideClicks()
        } else {
            showingSettings = false
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startMonitoringOutsideClicks()
            // Automatically refresh if data is older than 60s or any provider had an error.
            Task { await store.refreshIfStale(maxAge: 60) }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "立即重新整理", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let updateItem = NSMenuItem(title: "檢查 GitHub 更新…", action: #selector(menuCheckUpdates), keyEquivalent: "u")
        updateItem.target = self
        menu.addItem(updateItem)

        let settingsItem = NSMenuItem(title: "設定…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "結束 UsageView", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() {
        Task { await store.refresh(manual: true) }
    }

    @objc private func menuCheckUpdates() {
        showingSettings = true
        if let button = statusItem.button, !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        Task { await updater.checkForUpdates() }
    }

    @objc private func menuSettings() {
        showingSettings = true
        if let button = statusItem.button, !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    private func startMonitoringOutsideClicks() {
        stopMonitoringOutsideClicks()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
                self?.stopMonitoringOutsideClicks()
            }
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
