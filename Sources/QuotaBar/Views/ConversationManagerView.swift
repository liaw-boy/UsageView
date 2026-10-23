import AppKit
import QuotaBarCore
import SwiftUI

public struct ConversationManagerView: View {
    var onBack: () -> Void

    @State private var sessions: [ConversationSession] = []
    @State private var stats = ConversationManager.StorageStats()
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var selectedProvider: ProviderFilter = .all
    @State private var sortOption: SortOption = .sizeDesc
    @State private var previewSession: ConversationSession? = nil
    @State private var previewMessages: [ConversationMessage] = []
    @State private var isCleaningOld = false
    @State private var alertMessage: String? = nil
    @State private var showAlert = false
    @State private var freedToastText: String? = nil

    enum ProviderFilter: Hashable {
        case all, claude, antigravity

        var title: String {
            switch self {
            case .all: "全部"
            case .claude: "Claude"
            case .antigravity: "Antigravity"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case sizeDesc = "依容量大小"
        case dateDesc = "依更新時間"
        var id: String { rawValue }
    }

    public init(onBack: @escaping () -> Void) {
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 8) {
            header
            storageOverviewCard
            filterBar
            conversationList
        }
        .frame(maxWidth: .infinity)
        .task {
            await loadData()
        }
        .sheet(item: $previewSession) { session in
            previewSheet(session)
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

    private var header: some View {
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

                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.brandColor(.claude))
                        .frame(width: max(0, geo.size.width * claudeFrac - 1))
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
                    Text("Claude: \(stats.formattedClaude) (\(stats.claudeCount) 筆)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Theme.brandColor(.antigravity)).frame(width: 6, height: 6)
                    Text("Antigravity: \(stats.formattedAntigravity) (\(stats.antigravityCount) 筆)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                Text("安全保障：刪除的對話將移至 macOS 垃圾桶，可隨時復原。")
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
                .help("將超過 14 天且大於 50MB 的舊對話移至垃圾桶釋放空間")
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
                        Button(opt.rawValue) { sortOption = opt }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(sortOption.rawValue)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4.5)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 4) {
                filterTab(title: "全部 (\(sessions.count))", filter: .all)
                filterTab(title: "Claude (\(stats.claudeCount))", filter: .claude)
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
        case .dateDesc:
            list.sort { $0.updatedAt > $1.updatedAt }
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
        .frame(height: 290)
    }

    private func sessionRow(_ session: ConversationSession) -> some View {
        VStack(alignment: .leading, spacing: 4.5) {
            HStack(spacing: 5) {
                ProviderLogoView(provider: session.provider, size: 12.5, tinted: true)
                Text(session.projectName)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brandColor(session.provider))
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(session.formattedRelativeTime)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))

                sizeBadge(session.totalSizeBytes, label: session.formattedSize)
            }

            Text(session.prompt)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Button {
                    openPreview(session)
                } label: {
                    HStack(spacing: 2.5) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 8.5))
                        Text("預覽")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                Button {
                    revealInFinder(session)
                } label: {
                    HStack(spacing: 2.5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 8.5))
                        Text("訪達")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("在 macOS Finder 中顯示檔案")

                Button {
                    exportMarkdown(session)
                } label: {
                    HStack(spacing: 2.5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 8.5))
                        Text("匯出")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("將此對話匯出為 Markdown 格式文件")

                Spacer(minLength: 0)

                Button {
                    trashSession(session)
                } label: {
                    HStack(spacing: 2.5) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 8.5))
                        Text("丟入垃圾桶")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.98, green: 0.38, blue: 0.42))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.98, green: 0.38, blue: 0.42).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("移至 macOS 垃圾桶，可安全復原")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.8))
    }

    private func sizeBadge(_ bytes: Int64, label: String) -> some View {
        let isHuge = bytes >= 500 * 1024 * 1024
        let isBig = bytes >= 50 * 1024 * 1024
        let color = isHuge ? Color(red: 0.98, green: 0.35, blue: 0.35) : (isBig ? Color(red: 0.98, green: 0.72, blue: 0.22) : Color.white.opacity(0.65))

        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(isBig ? 0.16 : 0.08), in: Capsule())
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
                    if session.provider == .claude {
                        self.stats.claudeBytes = max(0, self.stats.claudeBytes - freed)
                        self.stats.claudeCount = max(0, self.stats.claudeCount - 1)
                    } else {
                        self.stats.antigravityBytes = max(0, self.stats.antigravityBytes - freed)
                        self.stats.antigravityCount = max(0, self.stats.antigravityCount - 1)
                    }
                    self.stats.totalBytes = self.stats.claudeBytes + self.stats.antigravityBytes
                    showToast("已移至垃圾桶，釋放 \(freedStr)")
                }
            } catch {
                alertMessage = "移至垃圾桶失敗：\(error.localizedDescription)"
                showAlert = true
            }
        }
    }

    private func cleanOldSessionsPrompt() {
        // Find sessions > 14 days and > 50MB
        let oldThreshold = Date().addingTimeInterval(-14 * 86400)
        let candidates = sessions.filter { $0.updatedAt < oldThreshold && $0.totalSizeBytes >= 50 * 1024 * 1024 }
        let totalCandBytes = candidates.reduce(0) { $0 + $1.totalSizeBytes }

        guard !candidates.isEmpty else {
            alertMessage = "目前沒有超過 14 天且大於 50MB 的舊對話，空間狀態健康！"
            showAlert = true
            return
        }

        let candStr = formatBytesBrief(totalCandBytes)
        let alert = NSAlert()
        alert.messageText = "確定執行一鍵清理並釋放空間？"
        alert.informativeText = "將把 \(candidates.count) 筆超過 14 天且大於 50MB 的舊對話移至垃圾桶。\n\n預計可釋放 \(candStr) 空間！\n（檔案均移至 macOS 垃圾桶，不會直接抹除，需要時可放回原處）"
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

    // MARK: - Preview Sheet

    private func previewSheet(_ session: ConversationSession) -> some View {
        VStack(spacing: 8) {
            HStack {
                ProviderLogoView(provider: session.provider, size: 14, tinted: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(session.id)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button {
                    previewSession = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Divider().overlay(Color.white.opacity(0.10))

            ScrollView(.vertical) {
                if previewMessages.isEmpty {
                    VStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("讀取訊息中…")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(previewMessages) { msg in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(msg.role == "User" ? "👤 使用者" : "🤖 \(msg.role)")
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                        .foregroundStyle(msg.role == "User" ? Color(red: 0.40, green: 0.75, blue: 1.0) : Theme.brandColor(session.provider))
                                    Spacer()
                                    if let ts = msg.timestamp {
                                        Text(ts, style: .time)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.40))
                                    }
                                }
                                Text(msg.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(msg.role == "User" ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
            .frame(height: 280)

            HStack {
                Button("在訪達中顯示") {
                    revealInFinder(session)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.70))

                Spacer()

                Button("匯出為 Markdown") {
                    exportMarkdown(session)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 380)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .dark)
    }
}
