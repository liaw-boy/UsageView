import AppKit
import QuotaBarCore
import SwiftUI

public struct ConversationManagerView: View {
    var onBack: () -> Void
    var embedded = false
    @ObservedObject var settings: SettingsStore

    @State private var sessions: [ConversationSession] = []
    @State private var stats = ConversationManager.StorageStats()
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var selectedProvider: ProviderFilter = .all
    @State private var sortOption: SortOption = .sizeDesc
    @State private var previewSession: ConversationSession? = nil
    @State private var previewMessages: [ConversationMessage] = []
    @State private var previewNewestFirst = true
    @State private var isCleaningOld = false
    @State private var alertMessage: String? = nil
    @State private var showAlert = false
    @State private var freedToastText: String? = nil

    enum ProviderFilter: Hashable {
        case all, claude, codex, antigravity

        var title: String {
            switch self {
            case .all: "全部"
            case .claude: "Claude"
            case .codex: "Codex"
            case .antigravity: "Antigravity"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case sizeDesc = "容量：大到小"
        case sizeAsc  = "容量：小到大"
        case dateDesc = "時間：新到舊"
        case dateAsc  = "時間：舊到新"

        var id: String { rawValue }
    }

    public init(settings: SettingsStore, embedded: Bool = false, onBack: @escaping () -> Void) {
        self.settings = settings
        self.embedded = embedded
        self.onBack = onBack
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Main conversation & storage management list
            VStack(spacing: 8) {
                header
                storageOverviewCard
                filterBar
                conversationList
            }
            .panelSized(embedded: embedded)
            .opacity(previewSession == nil ? 1 : 0)
            .disabled(previewSession != nil)

            // In-place full preview overlay (matching exact background bounds)
            if let session = previewSession {
                previewFullView(session)
                    .panelSized(embedded: embedded)
                    .transition(.opacity)
            }
        }
        .panelSized(embedded: embedded)
        .task {
            await loadData()
        }
        .alert("空間清理通知", isPresented: $showAlert) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = freedToastText {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.30, green: 0.88, blue: 0.56))
                    Text(toast)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.85), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(radius: 6)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if embedded {
            PageHeader(title: "對話管理", subtitle: "對話紀錄與硬碟空間") { refreshButton }
        } else {
            HStack(spacing: 6) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("返回面板")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("對話紀錄與空間管理")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await loadData() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 25, height: 25)
                .background(Theme.cardBackground, in: Circle())
                .overlay(Circle().strokeBorder(Theme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("重新掃描對話紀錄與磁碟空間")
    }

    // MARK: - Storage Overview Card

    private var storageOverviewCard: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.22))
                    Text("對話歷史總佔用空間")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Text(stats.formattedTotal)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.35))
            }

            // Visual bar
            GeometryReader { geo in
                let total = max(1, stats.totalBytes)
                let claudeFrac = CGFloat(stats.claudeBytes) / CGFloat(total)
                let antiFrac = CGFloat(stats.antigravityBytes) / CGFloat(total)
                let codexFrac = CGFloat(stats.codexBytes) / CGFloat(total)

                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.brandColor(.claude))
                        .frame(width: max(0, geo.size.width * claudeFrac - 1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.brandColor(.codex))
                        .frame(width: max(0, geo.size.width * codexFrac - 1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.brandColor(.antigravity))
                        .frame(width: max(0, geo.size.width * antiFrac - 1))
                }
            }
            .frame(height: 7)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3.5))

            HStack {
                HStack(spacing: 4) {
                    Circle().fill(Theme.brandColor(.claude)).frame(width: 6, height: 6)
                    Text("Claude \(stats.formattedClaude) · \(stats.claudeCount)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Theme.brandColor(.codex)).frame(width: 6, height: 6)
                    Text("Codex \(stats.formattedCodex) · \(stats.codexCount)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Theme.brandColor(.antigravity)).frame(width: 6, height: 6)
                    Text("Antigravity \(stats.formattedAntigravity) · \(stats.antigravityCount)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                Text("刪除的對話移至 macOS 垃圾桶，可復原。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                Spacer()
                Button {
                    cleanOldSessionsPrompt()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        Text("釋放空間")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.30, green: 0.88, blue: 0.56))
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.30, green: 0.88, blue: 0.56).opacity(0.15), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(red: 0.30, green: 0.88, blue: 0.56).opacity(0.35), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("將超過 \(settings.cleanupMinAgeDays) 天且大於 \(settings.cleanupMinSizeMB)MB 的舊對話移至垃圾桶釋放空間")

                Menu {
                    Picker("超過天數", selection: $settings.cleanupMinAgeDays) {
                        ForEach(SettingsStore.cleanupAgeOptions, id: \.self) { Text("超過 \($0) 天").tag($0) }
                    }
                    Picker("單筆大小", selection: $settings.cleanupMinSizeMB) {
                        ForEach(SettingsStore.cleanupSizeOptions, id: \.self) { Text("大於 \($0) MB").tag($0) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("調整一鍵清理的條件")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    }

    // MARK: - Filter & Search Bar

    private var filterBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    TextField("搜尋提示詞、專案名稱或 ID…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardBorder, lineWidth: 1))

                Menu {
                    ForEach(SortOption.allCases) { opt in
                        Button {
                            sortOption = opt
                        } label: {
                            HStack {
                                Text(opt.rawValue)
                                if sortOption == opt {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        Text(sortOption.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    .foregroundStyle(.white.opacity(0.90))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            HStack(spacing: 4) {
                filterTab(title: "全部 (\(sessions.count))", filter: .all)
                filterTab(title: "Claude (\(stats.claudeCount))", filter: .claude)
                filterTab(title: "Codex (\(stats.codexCount))", filter: .codex)
                filterTab(title: "Antigravity (\(stats.antigravityCount))", filter: .antigravity)
                Spacer()
            }
        }
    }

    private func filterTab(title: String, filter: ProviderFilter) -> some View {
        Button {
            selectedProvider = filter
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: selectedProvider == filter ? .bold : .medium, design: .rounded))
                .foregroundStyle(selectedProvider == filter ? .white : .white.opacity(0.55))
                .padding(.horizontal, 7.5)
                .padding(.vertical, 2.5)
                .background(selectedProvider == filter ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Conversation List

    private var filteredSessions: [ConversationSession] {
        var list = sessions

        switch selectedProvider {
        case .all: break
        case .claude: list = list.filter { $0.provider == .claude }
        case .codex: list = list.filter { $0.provider == .codex }
        case .antigravity: list = list.filter { $0.provider == .antigravity }
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.prompt.lowercased().contains(q) ||
                $0.projectName.lowercased().contains(q) ||
                $0.id.lowercased().contains(q)
            }
        }

        switch sortOption {
        case .sizeDesc:
            list.sort { $0.totalSizeBytes > $1.totalSizeBytes }
        case .sizeAsc:
            list.sort { $0.totalSizeBytes < $1.totalSizeBytes }
        case .dateDesc:
            list.sort { $0.updatedAt > $1.updatedAt }
        case .dateAsc:
            list.sort { $0.updatedAt < $1.updatedAt }
        }

        return list
    }

    private var conversationList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.85)
                    Text("正在掃描本機對話與磁碟佔用…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.60))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else if filteredSessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(searchText.isEmpty ? "目前無對話紀錄" : "找不到符合「\(searchText)」的對話")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(filteredSessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(height: embedded ? nil : 315)
    }

    @ViewBuilder
    private func sessionRow(_ session: ConversationSession) -> some View {
        if embedded {
            HoverRow { hovering in embeddedRow(session, hovering: hovering) }
        } else {
            popoverRow(session)
        }
    }

    /// Single-line row for the wide main window: actions are icon-only and appear on hover.
    private func embeddedRow(_ session: ConversationSession, hovering: Bool) -> some View {
        let brand = Theme.brandColor(session.provider)
        return HStack(spacing: 12) {
            ProviderLogoView(provider: session.provider, size: 16, tinted: true)
                .frame(width: 34, height: 34)
                .background(brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(brand)
                        .lineLimit(1)
                    Text(session.formattedRelativeTime)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(session.prompt)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                iconAction("eye.fill", help: "預覽對話內容") { openPreview(session) }
                iconAction("folder.fill", help: "在 Finder 中顯示") { revealInFinder(session) }
                iconAction("square.and.arrow.up", help: "匯出為 Markdown") { exportMarkdown(session) }
                iconAction("trash.fill", help: "移至垃圾桶，可安全復原", tint: Color(red: 0.98, green: 0.38, blue: 0.42)) {
                    trashSession(session)
                }
            }
            .opacity(hovering ? 1 : 0)

            sizeBadge(session.totalSizeBytes, label: session.formattedSize)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.025 : 0))
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.8))
        .animation(.easeInOut(duration: 0.2), value: hovering)
    }

    private func iconAction(_ symbol: String, help: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func popoverRow(_ session: ConversationSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderLogoView(provider: session.provider, size: 14, tinted: true)
                Text(session.projectName)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brandColor(session.provider))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(session.formattedRelativeTime)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))

                sizeBadge(session.totalSizeBytes, label: session.formattedSize)
            }

            Text(session.prompt)
                .font(.system(size: 12.5, weight: .regular))
                .lineSpacing(2.5)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                Button {
                    openPreview(session)
                } label: {
                    HStack(alignment: .center, spacing: 3.5) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .offset(y: 0.2)
                        Text("預覽")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8.5)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                }
                .buttonStyle(.plain)

                Button {
                    revealInFinder(session)
                } label: {
                    HStack(alignment: .center, spacing: 3.5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .offset(y: 0.1)
                        Text("Finder")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8.5)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("在 macOS Finder 中顯示檔案")

                Button {
                    exportMarkdown(session)
                } label: {
                    HStack(alignment: .center, spacing: 3.5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 9.5, weight: .semibold))
                            .offset(y: -0.6)
                        Text("匯出")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8.5)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("將此對話匯出為 Markdown 格式文件")

                Spacer(minLength: 0)

                Button {
                    trashSession(session)
                } label: {
                    HStack(alignment: .center, spacing: 3.5) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .offset(y: -0.2)
                        Text("丟入垃圾桶")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.98, green: 0.38, blue: 0.42))
                    .padding(.horizontal, 8.5)
                    .frame(height: 24)
                    .background(Color(red: 0.98, green: 0.38, blue: 0.42).opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(red: 0.98, green: 0.38, blue: 0.42).opacity(0.35), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("移至 macOS 垃圾桶，可安全復原")
            }
        }
        .padding(.horizontal, 10.5)
        .padding(.vertical, 8)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.8))
    }

    private func sizeBadge(_ bytes: Int64, label: String) -> some View {
        let isHuge = bytes >= 500 * 1024 * 1024
        let isBig = bytes >= 50 * 1024 * 1024
        let color = isHuge ? Color(red: 0.98, green: 0.35, blue: 0.35) : (isBig ? Color(red: 0.98, green: 0.72, blue: 0.22) : Color.white.opacity(0.70))

        return Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(isBig ? 0.18 : 0.09), in: Capsule())
    }

    // MARK: - Actions

    private func loadData() async {
        isLoading = true
        let (s, st) = await ConversationManager.shared.scanAll()
        await MainActor.run {
            self.sessions = s
            self.stats = st
            self.isLoading = false
        }
    }

    private func openPreview(_ session: ConversationSession) {
        previewSession = session
        previewMessages = []
        previewNewestFirst = true
        Task {
            let msgs = await ConversationManager.shared.loadPreviewMessages(session: session, limit: 40)
            await MainActor.run {
                self.previewMessages = msgs
            }
        }
    }

    private func revealInFinder(_ session: ConversationSession) {
        let url = URL(fileURLWithPath: session.mainFilePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportMarkdown(_ session: ConversationSession) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(session.projectName)-\(session.id.prefix(8)).md"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await ConversationManager.shared.exportToMarkdown(session: session, targetURL: url)
                    showToast("已成功匯出至 \(url.lastPathComponent)")
                } catch {
                    alertMessage = "匯出失敗：\(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }

    private func trashSession(_ session: ConversationSession) {
        Task {
            do {
                let freed = try await ConversationManager.shared.moveToTrash(session: session)
                let freedStr = formatBytesBrief(freed)
                await MainActor.run {
                    self.sessions.removeAll { $0.id == session.id }
                    switch session.provider {
                    case .claude:
                        self.stats.claudeBytes = max(0, self.stats.claudeBytes - freed)
                        self.stats.claudeCount = max(0, self.stats.claudeCount - 1)
                    case .codex:
                        self.stats.codexBytes = max(0, self.stats.codexBytes - freed)
                        self.stats.codexCount = max(0, self.stats.codexCount - 1)
                    case .antigravity:
                        self.stats.antigravityBytes = max(0, self.stats.antigravityBytes - freed)
                        self.stats.antigravityCount = max(0, self.stats.antigravityCount - 1)
                    case .opencode:
                        break // OpenCode sessions live in its database; the cleaner never lists them.
                    }
                    self.stats.totalBytes = self.stats.claudeBytes + self.stats.antigravityBytes + self.stats.codexBytes
                    showToast("已移至垃圾桶，釋放 \(freedStr)")
                }
            } catch {
                alertMessage = "移至垃圾桶失敗：\(error.localizedDescription)"
                showAlert = true
            }
        }
    }

    private func cleanOldSessionsPrompt() {
        let days = settings.cleanupMinAgeDays
        let mb = settings.cleanupMinSizeMB
        let candidates = ConversationManager.cleanupCandidates(from: sessions, minAgeDays: days, minSizeMB: mb)
        let totalCandBytes = candidates.reduce(0) { $0 + $1.totalSizeBytes }

        guard !candidates.isEmpty else {
            alertMessage = "目前沒有超過 \(days) 天且大於 \(mb)MB 的舊對話，空間狀態健康！"
            showAlert = true
            return
        }

        let candStr = formatBytesBrief(totalCandBytes)
        let alert = NSAlert()
        alert.messageText = "確定執行一鍵清理並釋放空間？"
        alert.informativeText = "將把 \(candidates.count) 筆超過 \(days) 天且大於 \(mb)MB 的舊對話移至垃圾桶。\n\n預計可釋放 \(candStr) 空間！\n（檔案均移至 macOS 垃圾桶，不會直接抹除，需要時可放回原處）"
        alert.addButton(withTitle: "移至垃圾桶釋放 \(candStr)")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                let (freed, count) = await ConversationManager.shared.batchMoveToTrash(sessions: candidates)
                await loadData()
                showToast("清理完成！共 \(count) 筆對話移至垃圾桶，釋放 \(formatBytesBrief(freed))")
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            freedToastText = text
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.25)) {
                freedToastText = nil
            }
        }
    }

    private func formatBytesBrief(_ b: Int64) -> String {
        let bytes = Double(b)
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", bytes / (1024 * 1024 * 1024))
        } else if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        } else {
            return "\(b / 1024) KB"
        }
    }

    // MARK: - In-Place Full Preview View (Matching exact background height & width)

    private func previewFullView(_ session: ConversationSession) -> some View {
        let displayedMessages: [ConversationMessage] = previewNewestFirst ? Array(previewMessages.reversed()) : previewMessages

        return VStack(spacing: 7) {
            // Header bar
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        previewSession = nil
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("返回列表")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 5) {
                    ProviderLogoView(provider: session.provider, size: 14, tinted: true)
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        previewSession = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
            }

            // Sub-header toolbar: ID & Relative time + sorting toggle
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(previewMessages.isEmpty ? "讀取中…" : "最近 \(previewMessages.count) 則對話")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                        Text("•")
                            .foregroundStyle(.white.opacity(0.30))
                        Text(session.formattedRelativeTime)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                    Text(session.id)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.40))
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        previewNewestFirst.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: previewNewestFirst ? "arrow.down.to.line" : "arrow.up.to.line")
                            .font(.system(size: 9, weight: .bold))
                        Text(previewNewestFirst ? "最新在最前 (預設)" : "依時間順序 (舊到新)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.40, green: 0.75, blue: 1.0))
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.40, green: 0.75, blue: 1.0).opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(red: 0.40, green: 0.75, blue: 1.0).opacity(0.25), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("切換對話排列順序")
            }

            Divider().overlay(Color.white.opacity(0.10))

            // Scrollable messages list filling all remaining middle space
            ScrollView(.vertical) {
                if previewMessages.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text("讀取訊息中…")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, msg in
                            let isLatest = previewNewestFirst ? (index == 0) : (index == displayedMessages.count - 1)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .center) {
                                    HStack(spacing: 4) {
                                        if msg.role == "User" {
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 10, weight: .semibold))
                                        } else {
                                            ProviderLogoView(provider: session.provider, size: 12, tinted: true)
                                        }
                                        Text(msg.role == "User" ? "使用者" : msg.role)
                                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(msg.role == "User" ? Color(red: 0.40, green: 0.75, blue: 1.0) : Theme.brandColor(session.provider))

                                    if isLatest {
                                        HStack(spacing: 2.5) {
                                            Circle()
                                                .fill(Color(red: 0.35, green: 0.85, blue: 0.55))
                                                .frame(width: 4.5, height: 4.5)
                                            Text("最新內容")
                                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                        }
                                        .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.55))
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1.5)
                                        .background(Color(red: 0.35, green: 0.85, blue: 0.55).opacity(0.14), in: Capsule())
                                    }

                                    Spacer()

                                    if !msg.formattedTimestamp.isEmpty {
                                        Text(msg.formattedTimestamp)
                                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.40))
                                    }
                                }

                                Group {
                                    if msg.role == "User" {
                                        Text(msg.text)
                                            .font(.system(size: embedded ? 13 : 11.5))
                                            .lineSpacing(embedded ? 3.5 : 2)
                                            .textSelection(.enabled)
                                    } else {
                                        MarkdownTextView(
                                            text: msg.text,
                                            fontSize: embedded ? 13 : 11.5,
                                            lineSpacing: embedded ? 3.5 : 2
                                        )
                                    }
                                }
                                .foregroundStyle(.white.opacity(0.92))
                            }
                            .padding(.horizontal, embedded ? 14 : 9)
                            .padding(.vertical, embedded ? 11 : 7)
                            .background(isLatest ? Color.white.opacity(0.08) : (msg.role == "User" ? Color.white.opacity(0.05) : Color.white.opacity(0.025)))
                            .clipShape(RoundedRectangle(cornerRadius: embedded ? 10 : 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: embedded ? 10 : 6)
                                    .strokeBorder(isLatest ? Color(red: 0.35, green: 0.85, blue: 0.55).opacity(0.35) : Color.clear, lineWidth: 0.8)
                            )
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .frame(height: embedded ? nil : 380)

            Divider().overlay(Color.white.opacity(0.10))

            // Footer actions
            HStack {
                Button {
                    revealInFinder(session)
                } label: {
                    HStack(alignment: .center, spacing: 3.5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9.5))
                            .offset(y: 0.1)
                        Text("在 Finder 中顯示")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    exportMarkdown(session)
                } label: {
                    HStack(alignment: .center, spacing: 3.5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 9.5))
                            .offset(y: -0.6)
                        Text("匯出為 Markdown")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .background(Color(red: 0.18, green: 0.52, blue: 0.95), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .panelSized(embedded: embedded)
        .background(Theme.panelBackground)
    }
}

/// Tracks pointer hover for a list row and hands the state to its content.
private struct HoverRow<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}
