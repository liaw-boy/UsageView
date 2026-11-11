import AppKit
import QuotaBarCore
import SwiftUI

enum MainPage: String, CaseIterable, Identifiable {
    case settings, stats, conversations, tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: "設定"
        case .stats: "用量統計"
        case .conversations: "對話管理"
        case .tools: "工具管理"
        }
    }

    var icon: String {
        switch self {
        case .settings: "slider.horizontal.3"
        case .stats: "chart.bar.xaxis"
        case .conversations: "bubble.left.and.bubble.right"
        case .tools: "puzzlepiece.extension"
        }
    }
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var page: MainPage = .settings
    @Published var statsProvider: ProviderID?
}

/// Standalone, resizable window hosting Settings / Usage statistics / Conversations / Tools behind a sidebar.
/// While it is open the app shows a Dock icon (`.regular`); closing it returns to a pure menu bar app (`.accessory`).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private let model = MainWindowModel()
    private var window: NSWindow?
    private var store: SnapshotStore?
    private var settings: SettingsStore?
    private var updater: UpdateService?

    func configure(store: SnapshotStore, settings: SettingsStore, updater: UpdateService) {
        self.store = store
        self.settings = settings
        self.updater = updater
    }

    func show(page: MainPage, statsProvider: ProviderID? = nil) {
        guard let store, let settings, let updater else { return }
        model.page = page
        model.statsProvider = statsProvider
        if window == nil {
            let hosting = NSHostingController(
                rootView: MainWindowView(model: model, store: store, settings: settings, updater: updater)
            )
            let w = NSWindow(contentViewController: hosting)
            w.title = "UsageView"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.setContentSize(NSSize(width: 920, height: 640))
            w.minSize = NSSize(width: 760, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: UpdateService

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 188)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.panelBackground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UsageView")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    lastUpdatedText
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 14)

            ForEach(MainPage.allCases) { page in
                let selected = model.page == page
                Button {
                    model.page = page
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.icon).frame(width: 18)
                        Text(page.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.68))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.08) : .clear))
                    .overlay(alignment: .leading) {
                        if selected {
                            UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                                .fill(Theme.brandColor(.claude))
                                .frame(width: 3)
                                .padding(.vertical, 7)
                                .offset(x: -10)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            quotaSummary
            HStack {
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                Spacer()
                Text(updateLabel)
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.22).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var lastUpdatedText: some View {
        if let date = store.lastUpdated {
            Text("更新於 ") + Text(date, style: .relative) + Text(" 前")
        } else {
            Text("尚未更新")
        }
    }

    private var updateLabel: String {
        switch updater.status {
        case .available: "有新版本"
        case .upToDate: "已是最新"
        default: ""
        }
    }

    /// 5H usage of every tracked provider, so the main window shows quota without going back to the menu bar.
    @ViewBuilder
    private var quotaSummary: some View {
        let rows = store.trackedProviders.compactMap { id in
            store.states[id]?.snapshot?.sessionPercent.map { (id, $0) }
        }
        if !rows.isEmpty {
            VStack(spacing: 7) {
                ForEach(rows, id: \.0) { id, used in
                    let shown = settings.showRemaining ? max(0, 100 - used) : used
                    let color = Theme.ringColor(for: id, usedPercent: used)
                    HStack(spacing: 7) {
                        ProviderLogoView(provider: id, size: 11, tinted: true)
                        Text("5H")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(color).frame(width: geo.size.width * min(max(shown, 0), 100) / 100)
                            }
                        }
                        .frame(height: 4)
                        Text(Theme.formattedPercent(used, showRemaining: settings.showRemaining))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(used >= 80 ? color : .white.opacity(0.8))
                            .frame(width: 34, alignment: .trailing)
                    }
                    .help("\(id.displayName) 5 小時窗口\(settings.showRemaining ? "剩餘" : "已用")")
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .settings:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "設定", subtitle: "追蹤、顯示位置、更新頻率與版本") { EmptyView() }
                    SettingsView(settings: settings, updater: updater)
                }
                .pageFrame()
            }
        case .stats:
            ScrollView {
                UsageStatisticsView(store: store, initialProvider: model.statsProvider, embedded: true, onBack: {})
                    .id(model.statsProvider)
                    .pageFrame()
            }
        case .conversations:
            ConversationManagerView(settings: settings, embedded: true, onBack: {})
                .pageFrame(scrolls: false)
        case .tools:
            ToolManagerView()
        }
    }
}

/// Left-aligned page title shared by every page of the main window.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            trailing
        }
    }
}

extension View {
    /// Shared content column of the main window: same width and gutters on every page.
    func pageFrame(scrolls: Bool = true) -> some View {
        self
            .frame(maxWidth: 760, maxHeight: scrolls ? nil : .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : .infinity, alignment: .top)
    }

    /// Fixed popover size, or fill the available space when hosted in the main window.
    @ViewBuilder
    func panelSized(embedded: Bool, width: CGFloat = 368, height: CGFloat = 508) -> some View {
        if embedded {
            frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            frame(width: width, height: height)
        }
    }
}
