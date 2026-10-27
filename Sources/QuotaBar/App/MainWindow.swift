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
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                Text("UsageView")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)

            ForEach(MainPage.allCases) { page in
                Button {
                    model.page = page
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.icon).frame(width: 18)
                        Text(page.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(model.page == page ? 1 : 0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(model.page == page ? Color.white.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.22).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1).ignoresSafeArea()
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
