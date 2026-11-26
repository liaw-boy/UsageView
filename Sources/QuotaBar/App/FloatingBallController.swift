import AppKit
import Combine
import QuotaBarCore
import SwiftUI

/// Always-on-top, draggable floating ball / pill widget that frees up macOS menu bar space.
/// Left-click toggles the Dashboard popover anchored to the widget; drag repositions it and persists its origin;
/// right-click opens a quick context menu.
@MainActor
final class FloatingBallController: NSObject {
    private let store: SnapshotStore
    private let settings: SettingsStore
    private weak var statusItem: StatusItemController?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<FloatingBallView>?
    private var dragView: FloatingDragContainerView?
    private var cancellables = Set<AnyCancellable>()

    init(store: SnapshotStore, settings: SettingsStore, statusItem: StatusItemController) {
        self.store = store
        self.settings = settings
        self.statusItem = statusItem
        super.init()

        settings.$floatingBallEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.setVisible(enabled)
            }
            .store(in: &cancellables)

        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncPanelSize()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clampPanelToVisibleScreen() }
        }

        if settings.floatingBallEnabled {
            setVisible(true)
        }
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil {
                createPanel()
            }
            syncPanelSize()
            clampPanelToVisibleScreen()
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let rootView = FloatingBallView(store: store, settings: settings)
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let container = FloatingDragContainerView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.onClick = { [weak self] view in
            self?.handleLeftClick(from: view)
        }
        container.onRightClick = { [weak self] view, event in
            self?.showContextMenu(from: view, event: event)
        }
        container.onDragEnded = { [weak self] origin in
            guard let self else { return }
            self.clampPanelToVisibleScreen()
            if let finalOrigin = self.panel?.frame.origin {
                self.settings.saveFloatingBallOrigin(finalOrigin)
            } else {
                self.settings.saveFloatingBallOrigin(origin)
            }
        }

        p.contentView = container
        self.panel = p
        self.hostingView = hosting
        self.dragView = container

        // Initial placement: saved origin or top-right corner of main screen.
        let size = hosting.fittingSize
        let initialSize = NSSize(width: max(54, size.width), height: max(36, size.height))
        if let saved = settings.savedFloatingBallOrigin() {
            p.setFrame(NSRect(origin: saved, size: initialSize), display: false)
        } else if let visible = NSScreen.main?.visibleFrame {
            let origin = NSPoint(x: visible.maxX - initialSize.width - 18,
                                 y: visible.maxY - initialSize.height - 18)
            p.setFrame(NSRect(origin: origin, size: initialSize), display: false)
        }
    }

    private func syncPanelSize() {
        guard panel != nil, hostingView != nil, settings.floatingBallEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let hosting = self.hostingView else { return }
            hosting.layoutSubtreeIfNeeded()
            let fit = hosting.fittingSize
            guard fit.width > 10, fit.height > 10 else { return }
            let newSize = NSSize(width: ceil(fit.width), height: ceil(fit.height))
            var frame = panel.frame
            if abs(frame.width - newSize.width) > 0.5 || abs(frame.height - newSize.height) > 0.5 {
                // Keep the right/top anchor stable when switching between orb and pill near the right edge.
                if let screen = panel.screen ?? NSScreen.main,
                   frame.midX > screen.visibleFrame.midX {
                    frame.origin.x = frame.maxX - newSize.width
                }
                frame.origin.y = frame.maxY - newSize.height
                frame.size = newSize
                panel.setFrame(frame, display: true)
                self.clampPanelToVisibleScreen()
            }
        }
    }

    private func clampPanelToVisibleScreen() {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var frame = panel.frame
        let margin: CGFloat = 6
        frame.origin.x = min(max(frame.origin.x, visible.minX + margin), max(visible.minX + margin, visible.maxX - frame.width - margin))
        frame.origin.y = min(max(frame.origin.y, visible.minY + margin), max(visible.minY + margin, visible.maxY - frame.height - margin))
        panel.setFrameOrigin(frame.origin)
    }

    private func handleLeftClick(from view: NSView) {
        guard let panel, let statusItem else { return }
        let screen = panel.screen ?? NSScreen.main
        let preferredEdge: NSRectEdge
        if let vis = screen?.visibleFrame {
            preferredEdge = panel.frame.midY > vis.midY ? .minY : .maxY
        } else {
            preferredEdge = .minY
        }
        statusItem.togglePopover(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
    }

    private func showContextMenu(from view: NSView, event: NSEvent) {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "立即重新整理", action: #selector(menuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let styleTitle = settings.floatingBallStyle == .orb ? "切換為「膠囊條」外觀" : "切換為「圓球」外觀"
        let styleItem = NSMenuItem(title: styleTitle, action: #selector(menuToggleStyle), keyEquivalent: "")
        styleItem.target = self
        menu.addItem(styleItem)

        let pctTitle = settings.showRemaining ? "切換為「已用 %」" : "切換為「剩餘 %」"
        let pctItem = NSMenuItem(title: pctTitle, action: #selector(menuToggleRemaining), keyEquivalent: "")
        pctItem.target = self
        menu.addItem(pctItem)

        let hideBarItem = NSMenuItem(title: "隱藏狀態列圖示", action: #selector(menuToggleHideMenuBar), keyEquivalent: "")
        hideBarItem.target = self
        hideBarItem.state = settings.hideMenuBarWhenFloating ? .on : .off
        menu.addItem(hideBarItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "設定…", action: #selector(menuOpenSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let hideBallItem = NSMenuItem(title: "關閉懸浮球（恢復狀態列）", action: #selector(menuHideBall), keyEquivalent: "")
        hideBallItem.target = self
        menu.addItem(hideBallItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "結束 UsageView", action: #selector(menuQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func menuRefresh() {
        Task { await store.refresh(manual: true) }
    }

    @objc private func menuToggleStyle() {
        settings.floatingBallStyle = settings.floatingBallStyle == .orb ? .pill : .orb
    }

    @objc private func menuToggleRemaining() {
        settings.showRemaining.toggle()
    }

    @objc private func menuToggleHideMenuBar() {
        settings.hideMenuBarWhenFloating.toggle()
    }

    @objc private func menuOpenSettings() {
        statusItem?.openMainWindow(.settings)
    }

    @objc private func menuHideBall() {
        settings.floatingBallEnabled = false
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}

/// Distinguishes click vs drag on the floating panel without stealing focus from other apps.
private final class FloatingDragContainerView: NSView {
    var onClick: ((NSView) -> Void)?
    var onRightClick: ((NSView, NSEvent) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    private var initialMouseScreen: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(self, event)
            return
        }
        initialMouseScreen = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - initialMouseScreen.x
        let dy = current.y - initialMouseScreen.y
        if !isDragging && hypot(dx, dy) >= 4 {
            isDragging = true
        }
        if isDragging {
            window.setFrameOrigin(NSPoint(x: initialWindowOrigin.x + dx, y: initialWindowOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            if let origin = window?.frame.origin {
                onDragEnded?(origin)
            }
        } else {
            onClick?(self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(self, event)
    }
}

// MARK: - SwiftUI Floating Ball / Pill View

private struct FloatingBallView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    @State private var isHovered = false

    private var activeItems: [(ProviderID, ProviderSnapshot)] {
        let providers = store.menuBarProviders.isEmpty ? store.trackedProviders : store.menuBarProviders
        return providers.compactMap { id -> (ProviderID, ProviderSnapshot)? in
            guard let snap = store.states[id]?.snapshot else { return nil }
            guard !snap.lines.isEmpty || snap.localSpend?.hasAnyUsage == true else { return nil }
            return (id, snap)
        }
    }

    private var orbItem: (ProviderID, ProviderSnapshot)? {
        guard !activeItems.isEmpty else { return nil }
        let idx = abs(store.carouselTick) % activeItems.count
        return activeItems[idx]
    }

    var body: some View {
        Group {
            switch settings.floatingBallStyle {
            case .orb:
                orbBody
            case .pill:
                pillBody
            }
        }
        .opacity(isHovered ? 1.0 : settings.floatingBallOpacity)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var orbBody: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.125, green: 0.133, blue: 0.153).opacity(0.94))
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(isHovered ? 0.28 : 0.14), lineWidth: 1)
                )

            if let (id, snap) = orbItem {
                if snap.lines.isEmpty {
                    VStack(spacing: 1) {
                        ProviderLogoView(provider: id, size: 13, tinted: true)
                        Text(MenuBarStripView.spendText(snap.localSpend?.todayCostUSD ?? 0))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                } else {
                    DualRingGauge(
                        provider: id,
                        lines: snap.lines,
                        showRemaining: settings.showRemaining,
                        size: 46,
                        lineWidth: 3.4
                    )
                    .overlay {
                        VStack(spacing: 0.5) {
                            ProviderLogoView(provider: id, size: 11, tinted: true)
                            Text(Theme.formattedPercent(snap.sessionPercent ?? 0, showRemaining: settings.showRemaining))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 1)
                        .background(Circle().fill(Color(red: 0.125, green: 0.133, blue: 0.153)).frame(width: 28, height: 28))
                    }
                }
            } else {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: 54, height: 54)
        .padding(4)
    }

    private var pillBody: some View {
        MenuBarStripView(store: store, settings: settings)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(red: 0.125, green: 0.133, blue: 0.153).opacity(0.94))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(isHovered ? 0.28 : 0.15), lineWidth: 1)
            )
            .padding(4)
    }
}
