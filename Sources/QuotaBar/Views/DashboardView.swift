import AppKit
import QuotaBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: UpdateService
    @ObservedObject var controller: StatusItemController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            VStack(spacing: 6) {
                if controller.showingSettings {
                    header
                    SettingsView(settings: settings, updater: updater)
                    footer
                } else if controller.showingConversations {
                    ConversationManagerView(
                        settings: settings,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                controller.showingConversations = false
                            }
                        }
                    )
                } else if controller.showingStats {
                    UsageStatisticsView(
                        store: store,
                        initialProvider: controller.statsProvider,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                controller.showingStats = false
                            }
                        }
                    )
                } else {
                    header
                    cardsContent
                    footer
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 392)
            .fixedSize(horizontal: true, vertical: true)
            .background(Theme.panelBackground)
            .environment(\.colorScheme, .dark)
        }
    }

    // MARK: - Compact Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(controller.showingSettings ? "偏好設定" : "UsageView")
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("v\(UpdateService.currentVersion)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08), in: Capsule())

                    if case .available(let newVer, _, _) = updater.status {
                        Button {
                            controller.openMainWindow(.settings)
                            Task { await updater.performUpdate() }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text("有新版 v\(newVer)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(.black.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color(red: 0.30, green: 0.88, blue: 0.56), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("點擊立即自動下載並更新至 v\(newVer)")
                    }
                }
                Text(updatedSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Button {
                settings.showRemaining.toggle()
            } label: {
                Text(settings.showRemaining ? "剩餘 %" : "已用 %")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 3.5)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("點擊切換「已用 %」與「剩餘 %」")

            Button {
                Task { await store.refresh(manual: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.90))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: store.isRefreshing
                    )
                    .frame(width: 25, height: 25)
                    .background(Theme.cardBackground, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("立即重新整理")
        }
    }

    private var syncInterval: String {
        let m = settings.refreshMinutes
        guard settings.isTracked(.claude), m < SnapshotStore.claudeMinimumRefreshMinutes else { return "每 \(m)m 自動同步" }
        return "每 \(m)m 自動同步（Claude 每 \(SnapshotStore.claudeMinimumRefreshMinutes)m）"
    }

    private var updatedSubtitle: String {
        guard let date = store.lastUpdated else { return "唯讀查詢 · \(syncInterval)" }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 30 { return "剛剛更新 · \(syncInterval)" }
        if secs < 3600 { return "更新於 \(secs / 60) 分鐘前 · \(syncInterval)" }
        return "更新於 \(secs / 3600) 小時前 · 點擊右上立即重試"
    }

    // MARK: - Cards Content (Always shows all enabled panel providers)

    @ViewBuilder
    private var cardsContent: some View {
        let visible = store.panelProviders
        if visible.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.45))
                Text("目前未勾選任何面板顯示服務")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Button("前往設定調整") {
                    controller.openMainWindow(.settings)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
            )
        } else {
            VStack(spacing: 7) {
                ForEach(visible) { id in
                    ProviderCardView(
                        provider: id,
                        state: store.states[id] ?? ProviderState(),
                        showRemaining: settings.showRemaining,
                        onToggleMode: { settings.showRemaining.toggle() },
                        isOffline: !store.isOnline,
                        onOpenStats: {
                            controller.openMainWindow(.stats, statsProvider: id)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Compact Footer

    @State private var sharedDashboardToast = false

    private var footer: some View {
        HStack(spacing: 5) {
            Button {
                controller.openMainWindow(.settings)
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "slider.horizontal.3")
                    Text("設定")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if !controller.showingSettings && !store.panelProviders.isEmpty {
                Button {
                    controller.openMainWindow(.stats)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 10))
                        Text("統計表")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("查看 Token 與花費統計表（當日 · 週 · 月）")

                Button {
                    controller.openMainWindow(.conversations)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 10))
                        Text("對話管理")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("管理本地對話紀錄與釋放硬碟空間")

                Button {
                    controller.openMainWindow(.tools)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 10))
                        Text("工具")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("開啟獨立視窗，管理 OpenCode / Claude Code / Codex 的 Skill、MCP、Plugin")

                Button {
                    ShareExporter.shareAllCards(store: store, showRemaining: settings.showRemaining)
                    withAnimation(.easeInOut(duration: 0.15)) { sharedDashboardToast = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.easeInOut(duration: 0.2)) { sharedDashboardToast = false }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: sharedDashboardToast ? "checkmark.circle.fill" : "square.and.arrow.up")
                            .font(.system(size: 10))
                        Text(sharedDashboardToast ? "已複製" : "分享")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(sharedDashboardToast ? Color(red: 0.30, green: 0.88, blue: 0.56) : .white.opacity(0.82))
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("開啟 macOS 原生分享選單並同步複製總覽圖卡到剪貼簿")
            }

            Spacer(minLength: 4)

            Button("結束") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white.opacity(0.60))
        }
    }
}

// MARK: - Provider Card (Native Neutral Dark Surface + Provider Logo)

struct ProviderCardView: View {
    let provider: ProviderID
    let state: ProviderState
    let showRemaining: Bool
    let onToggleMode: () -> Void
    var isSnapshotExport: Bool = false
    var isOffline: Bool = false
    var onOpenStats: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var copiedToast = false

    private var lines: [MetricLine] { state.snapshot?.lines ?? [] }

    private var headlinePace: Pace? {
        if provider == .antigravity,
           let gemini = lines.first(where: { $0.kind == .session && $0.pool == "gemini" }) {
            return gemini.pace
        }
        return lines.first(where: { $0.kind == .session })?.pace ?? lines.first?.pace
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Group {
                if provider == .opencode && lines.isEmpty {
                    ZStack {
                        Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 4.8)
                        if let today = state.snapshot?.localSpend?.todayCostUSD {
                            VStack(spacing: 0) {
                                Text(MenuBarStripView.spendText(today))
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.7)
                                Text("今日")
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        } else {
                            ProviderLogoView(provider: provider, size: 22, tinted: true)
                        }
                    }
                    .frame(width: 62, height: 62)
                } else {
                    DualRingGauge(provider: provider, lines: lines, showRemaining: showRemaining, size: 62, lineWidth: 4.8)
                        .onTapGesture(perform: onToggleMode)
                }
            }
            .opacity(state.isStale ? 0.65 : 1.0)

            VStack(alignment: .leading, spacing: 4.5) {
                HStack(spacing: 5.5) {
                    ProviderLogoView(provider: provider, size: 14.5, tinted: true)
                    Text(provider.displayName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    if let plan = state.snapshot?.planName, !plan.isEmpty {
                        PlanBadgeView(plan: plan, color: Theme.brandColor(provider))
                    }

                    if state.snapshot != nil, isOffline || state.error != nil {
                        HStack(spacing: 2.5) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9))
                            Text("快取")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .help(isOffline
                              ? "目前離線，顯示上次成功同步的快取資料，恢復連線後會自動更新"
                              : "官方 API 暫時冷卻中，目前顯示上次成功同步的快取資料（\(state.error ?? "")）")
                    }

                    Spacer(minLength: 2)

                    if let pace = headlinePace {
                        PaceChip(pace: pace)
                    }

                    if !isSnapshotExport && !lines.isEmpty {
                        Button {
                            triggerShare(openPicker: true)
                        } label: {
                            HStack(spacing: 2.5) {
                                Image(systemName: copiedToast ? "checkmark" : "square.and.arrow.up")
                                    .font(.system(size: 9.5, weight: .bold))
                                if copiedToast {
                                    Text("已複製")
                                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                }
                            }
                            .foregroundStyle(copiedToast ? Color(red: 0.30, green: 0.88, blue: 0.56) : .white.opacity(isHovered ? 0.88 : 0.48))
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(copiedToast ? Color(red: 0.30, green: 0.88, blue: 0.56).opacity(0.18) : Color.white.opacity(isHovered ? 0.12 : 0.05))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("分享 \(provider.displayName) 額度圖卡（開啟 macOS 分享選單並複製到剪貼簿）")
                    }
                }

                if lines.isEmpty {
                    if isOffline {
                        Text("目前離線，恢復連線後會自動更新")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    } else if let error = state.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else if provider == .opencode, state.snapshot != nil {
                        Text("本機花費統計 · 未設定額度上限")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        Text(state.isRefreshing ? "讀取中…" : "No data")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else {
                    VStack(spacing: 3.5) {
                        ForEach(lines) { line in
                            MetricBarRow(
                                provider: provider,
                                line: line,
                                showRemaining: showRemaining,
                                showDetail: isHovered
                            )
                        }
                    }
                    .opacity(state.isStale ? 0.78 : 1.0)
                }

                if let message = state.staleErrorMessage(isOffline: isOffline) {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.isRateLimited {
                        Text("手動重新整理可能讓限流更久，請耐心等候")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }

                if let snap = state.snapshot, snap.localSpend?.hasAnyUsage == true || snap.extraUsageText != nil {
                    CardSpendFooterRow(spend: snap.localSpend, extraUsageText: snap.extraUsageText, onOpenStats: onOpenStats)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8.5)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isHovered ? Theme.cardHoverBorder : Theme.cardBorder, lineWidth: 1)
                )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu {
            Button {
                triggerShare(openPicker: true)
            } label: {
                Label("分享 \(provider.displayName) 圖卡 (AirDrop / 訊息…)", systemImage: "square.and.arrow.up")
            }
            Button {
                triggerShare(openPicker: false)
            } label: {
                Label("複製 \(provider.displayName) 圖卡到剪貼簿", systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                onToggleMode()
            } label: {
                Label(showRemaining ? "切換為「已用 %」" : "切換為「剩餘 %」", systemImage: "percent")
            }
        }
    }

    @MainActor
    private func triggerShare(openPicker: Bool) {
        ShareExporter.shareSingleCard(
            provider: provider,
            state: state,
            showRemaining: showRemaining,
            openPicker: openPicker
        )
        withAnimation(.easeInOut(duration: 0.15)) { copiedToast = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.2)) { copiedToast = false }
        }
    }
}

private struct PlanBadgeView: View {
    let plan: String
    let color: Color

    var body: some View {
        Text(plan)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.38), lineWidth: 0.7))
    }
}

private struct CardSpendFooterRow: View {
    let spend: LocalSpendSummary?
    let extraUsageText: String?
    var onOpenStats: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            if let spend, spend.hasAnyUsage {
                Button {
                    onOpenStats?()
                } label: {
                    HStack(spacing: 4.5) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.62).opacity(0.88))
                        Text(spendLabel(spend))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            Text("統計表")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.62).opacity(0.85))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let extra = extraUsageText {
                HStack(spacing: 4.5) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(red: 0.56, green: 0.78, blue: 1.0).opacity(0.85))
                    Text(extra)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0.56, green: 0.78, blue: 1.0))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 1.5)
        .help("點擊查看詳細額度與 Token 用量統計表（100% 本機離線統計）")
    }

    private func spendLabel(_ s: LocalSpendSummary) -> String {
        let today = formatCostBrief(s.todayCostUSD)
        let week = formatCostBrief(s.weekCostUSD)
        let month = formatCostBrief(s.monthCostUSD)
        return "今日 \(today) · 7D \(week) · 30D \(month)"
    }

    private func formatCostBrief(_ cost: Double) -> String {
        if cost >= 1_000_000 {
            return String(format: "$%.2fM", cost / 1_000_000)
        } else if cost >= 1_000 {
            return String(format: "$%.2fK", cost / 1_000)
        } else {
            return String(format: "$%.2f", cost)
        }
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            return String(format: "%.2fB tok", Double(n) / 1_000_000_000)
        } else if n >= 1_000_000 {
            return String(format: "%.1fM tok", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.0fK tok", Double(n) / 1_000)
        }
        return "\(n) tok"
    }
}

@MainActor
private enum ShareExporter {
    static func shareSingleCard(
        provider: ProviderID,
        state: ProviderState,
        showRemaining: Bool,
        openPicker: Bool
    ) {
        let view = ShareCardSnapshotView(
            provider: provider,
            state: state,
            showRemaining: showRemaining
        )
        renderAndShare(view: view, fileName: "UsageView-\(provider.displayName).png", openPicker: openPicker)
    }

    static func shareAllCards(store: SnapshotStore, showRemaining: Bool) {
        let providers = store.panelProviders
        let view = ShareAllCardsSnapshotView(
            providers: providers,
            states: store.states,
            showRemaining: showRemaining
        )
        renderAndShare(view: view, fileName: "UsageView-Overview.png", openPicker: true)
    }

    private static func renderAndShare<V: View>(view: V, fileName: String, openPicker: Bool) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let nsImage = renderer.nsImage else { return }

        // 1. Always copy to clipboard for instant ⌘V pasting
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])

        // 2. Write a named PNG file so AirDrop, Messages, Mail, and Finder receive a proper .png file
        var shareItems: [Any] = [nsImage]
        if let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            if (try? png.write(to: fileURL, options: .atomic)) != nil {
                shareItems = [fileURL]
            }
        }

        // 3. Present native macOS Share menu (`NSSharingServicePicker`) at the current cursor location
        guard openPicker,
              let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let contentView = window.contentView
        else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = contentView.convert(mouseInWindow, from: nil)
        let anchorRect = NSRect(x: pointInView.x - 8, y: pointInView.y - 8, width: 16, height: 16)
        let picker = NSSharingServicePicker(items: shareItems)
        picker.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
    }
}

private struct ShareCardSnapshotView: View {
    let provider: ProviderID
    let state: ProviderState
    let showRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderCardView(
                provider: provider,
                state: state,
                showRemaining: showRemaining,
                onToggleMode: {},
                isSnapshotExport: true
            )
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("UsageView for macOS · github.com/liaw-boy/UsageView")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
                Spacer()
                Text(showRemaining ? "剩餘 %" : "已用 %")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 368)
        .background(Theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .padding(8)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        .environment(\.colorScheme, .dark)
    }
}

private struct ShareAllCardsSnapshotView: View {
    let providers: [ProviderID]
    let states: [ProviderID: ProviderState]
    let showRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("UsageView")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(showRemaining ? "剩餘 %" : "已用 %")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.cardBackground, in: Capsule())
            }
            .padding(.horizontal, 2)

            ForEach(providers) { id in
                ProviderCardView(
                    provider: id,
                    state: states[id] ?? ProviderState(),
                    showRemaining: showRemaining,
                    onToggleMode: {},
                    isSnapshotExport: true
                )
            }

            HStack {
                Text("github.com/liaw-boy/UsageView")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 368)
        .background(Theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .padding(8)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        .environment(\.colorScheme, .dark)
    }
}

private struct MetricBarRow: View {
    let provider: ProviderID
    let line: MetricLine
    let showRemaining: Bool
    let showDetail: Bool

    private var color: Color {
        if line.pool == "argon" && line.usedPercent < 80 {
            return Color(red: 0.95, green: 0.72, blue: 0.28)
        }
        return Theme.ringColor(for: provider, usedPercent: line.usedPercent, secondaryPool: line.pool == "3p")
    }

    var body: some View {
        GeometryReader { geo in
            // Progress bar always indicates usage (消耗量：用越多越長，越滿越接近警示色)
            let barFraction = line.usedPercent / 100.0
            let fillWidth = max(barFraction > 0.005 ? 4 : 0, geo.size.width * CGFloat(barFraction))
            // White time tick always indicates time elapsed from left (0%) to right (100%)
            let elapsedFraction = line.timeElapsedFraction()
            let tickFraction = elapsedFraction

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.35))
                    .frame(width: fillWidth)

                // Even-pace time tick mark (where steady linear usage would be right now)
                if let tick = tickFraction {
                    let tickX = min(max(3, geo.size.width * CGFloat(tick)), geo.size.width - 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 1.5, height: 17)
                        .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 0)
                        .offset(x: tickX - 0.75)
                }

                HStack(spacing: 4) {
                    Text(displayLabel)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 4)

                    Text(trailingText)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 7)
            }
        }
        .frame(height: 22)
        .help(tooltipText)
    }

    private var displayLabel: String {
        line.label
            .replacingOccurrences(of: "Gemini 4 Argon", with: "Argon")
            .replacingOccurrences(of: "5 小時", with: "5H")
            .replacingOccurrences(of: "5h", with: "5H")
            .replacingOccurrences(of: "每週 · ", with: "")
            .replacingOccurrences(of: "每週", with: "7D")
    }

    private var trailingText: String {
        let pct = Theme.formattedPercent(line.usedPercent, showRemaining: showRemaining)
        if line.isNotStarted { return "\(pct) · 可用" }
        guard let reset = line.resetsAt else { return pct }
        if showDetail { return "\(pct) · \(Self.exactResetText(reset))" }
        let secs = max(0, Int(reset.timeIntervalSinceNow))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let rel = h >= 24 ? "\(h / 24)d \(h % 24)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
        return "\(pct) · \(rel)"
    }

    /// Exact reset moment shown while the card is hovered: "今天 21:35", "明天 03:10" or "06/12 21:35".
    static func exactResetText(_ reset: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.dateFormat = "HH:mm"
        if calendar.isDate(reset, inSameDayAs: now) { return "今天 \(time.string(from: reset))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(reset, inSameDayAs: tomorrow) {
            return "明天 \(time.string(from: reset))"
        }
        let full = DateFormatter()
        full.calendar = calendar
        full.dateFormat = "MM/dd HH:mm"
        return full.string(from: reset)
    }

    private var tooltipText: String {
        let exactRemain = String(format: "%.2f%%", line.remainingPercent)
        let exactUsed = String(format: "%.2f%%", line.usedPercent)
        guard let reset = line.resetsAt, !line.isNotStarted else {
            return "\(displayLabel)：剩餘 \(exactRemain)（已用 \(exactUsed)）· 隨時可用"
        }
        let f = DateFormatter()
        f.dateFormat = "MM/dd (E) HH:mm"
        return "\(displayLabel)：剩餘 \(exactRemain)（已用 \(exactUsed)）· 重設時間 \(f.string(from: reset))"
    }
}

private struct PaceChip: View {
    let pace: Pace

    private var label: String {
        switch pace {
        case .useFaster: "⚡ 快一點用"
        case .comfortable: "👌 放心用"
        case .slowDown: "🐢 少用一點"
        case .conserve: "⚠️ 省著點用"
        case .almostGone: "🔥 要沒了！"
        }
    }

    private var tint: Color {
        switch pace {
        case .useFaster: Color(red: 0.22, green: 0.88, blue: 0.68)
        case .comfortable: Color(red: 0.45, green: 0.72, blue: 1.00)
        case .slowDown: Color(red: 1.00, green: 0.76, blue: 0.24)
        case .conserve: Color(red: 1.00, green: 0.52, blue: 0.22)
        case .almostGone: Color(red: 0.98, green: 0.30, blue: 0.36)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.18), in: Capsule())
    }
}

// MARK: - Settings View (Native Neutral Dark Surface + Provider Logos)

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: UpdateService
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 8) {
            providerMatrixCard
            displayModeCard
            if settings.isTracked(.opencode) { opencodeQuotaCard }
            scheduleAndAlertsCard
            updateCard
        }
    }

    private var providerMatrixCard: some View {
        SettingsCard(title: "服務追蹤與顯示位置", icon: "square.stack.3d.up.fill") {
            VStack(spacing: 6) {
                ForEach(ProviderID.allCases) { id in
                    let tracked = settings.isTracked(id)
                    let inPanel = settings.isShownInPanel(id)
                    let inBar = settings.isShownInMenuBar(id)
                    let accent = Theme.brandColor(id)

                    HStack(spacing: 7) {
                        ProviderLogoView(provider: id, size: 14, tinted: tracked)
                            .opacity(tracked ? 1.0 : 0.38)
                        Text(id.displayName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(tracked ? 0.95 : 0.45))

                        Spacer()

                        PillToggleButton(
                            title: "追蹤",
                            icon: tracked ? "bolt.fill" : "bolt.slash",
                            isOn: tracked,
                            accent: accent
                        ) {
                            settings.setTracked(id, !tracked)
                        }

                        PillToggleButton(
                            title: "面板",
                            icon: "rectangle.stack",
                            isOn: inPanel,
                            accent: accent
                        ) {
                            settings.setShownInPanel(id, !inPanel)
                        }

                        PillToggleButton(
                            title: "狀態列",
                            icon: "menubar.rectangle",
                            isOn: inBar,
                            accent: accent
                        ) {
                            settings.setShownInMenuBar(id, !inBar)
                        }
                    }
                }
            }
        }
    }

    private var opencodeQuotaCard: some View {
        SettingsCard(title: "OpenCode 額度（本機估算）", icon: "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("額度模式")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(OpenCodeQuotaMode.allCases, id: \.self) { mode in
                            let selected = settings.opencodeQuotaMode == mode
                            Button {
                                settings.opencodeQuotaMode = mode
                            } label: {
                                Text(mode.title)
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(selected ? .white : .white.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Color.clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                }

                if settings.opencodeQuotaMode == .custom {
                    budgetField(title: "5 小時預算 (USD)", value: $settings.opencodeSessionBudget)
                    budgetField(title: "每週預算 (USD)", value: $settings.opencodeWeeklyBudget)
                }

                Text(opencodeModeHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var opencodeModeHint: String {
        switch settings.opencodeQuotaMode {
        case .spendOnly: "只讀取本機 opencode.db 的花費紀錄，不連網、不消耗額度。"
        case .go: "只計 opencode-go 花費：5 小時 $12、每週 $30。各模型上限不同，百分比為估算。"
        case .goPlus: "只計 opencode-go 花費：5 小時 $48、每週 $120。各模型上限不同，百分比為估算。"
        case .custom: "以所有 provider 的本機花費對照你設定的預算。"
        }
    }

    private func budgetField(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
        }
    }

    private var displayModeCard: some View {
        SettingsCard(title: "狀態列顯示與輪播設定", icon: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("狀態列模式")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                    ModeSegmentedPicker(selection: $settings.menuBarDisplayMode)
                }

                // Immediately below "狀態列模式" when ".single" is selected!
                if settings.menuBarDisplayMode == .single && !settings.availableMenuBarProviders.isEmpty {
                    HStack(spacing: 6) {
                        Text("單一顯示")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            ForEach(settings.availableMenuBarProviders) { id in
                                let sel = settings.selectedSingleProvider == id
                                Button {
                                    settings.selectedSingleProvider = id
                                } label: {
                                    HStack(spacing: 3.5) {
                                        ProviderLogoView(provider: id, size: 10.5, tinted: true)
                                        Text(id.displayName)
                                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .foregroundStyle(sel ? .white : .white.opacity(0.55))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Capsule().fill(sel ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                HStack {
                    Text("狀態列週期")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(MenuBarMetricMode.allCases, id: \.self) { mode in
                            let selected = settings.menuBarMetricMode == mode
                            Button {
                                settings.menuBarMetricMode = mode
                            } label: {
                                Text(mode.title)
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(selected ? .white : .white.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? Color.white.opacity(0.18) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                }

                HStack {
                    Text("狀態列圖示")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                            let selected = settings.menuBarIconStyle == style
                            Button {
                                settings.menuBarIconStyle = style
                            } label: {
                                Text(style.title)
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(selected ? .white : .white.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? Color.white.opacity(0.18) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var scheduleAndAlertsCard: some View {
        SettingsCard(title: "自動更新頻率與提醒", icon: "bell.badge.fill") {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("背景自動更新")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(SettingsStore.refreshOptions, id: \.self) { m in
                            let selected = settings.refreshMinutes == m
                            Button {
                                settings.refreshMinutes = m
                            } label: {
                                Text("\(m)m")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .foregroundStyle(selected ? .white : .white.opacity(0.58))
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(selected ? Color.white.opacity(0.20) : Color.white.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Claude 的額度端點限流較嚴，Claude 最短每 \(SnapshotStore.claudeMinimumRefreshMinutes) 分鐘更新一次")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))

                Divider().overlay(Color.white.opacity(0.08))

                SettingsToggleRow(
                    title: "額度警示與滿血重置通知",
                    subtitle: "超過 80% / 95% 警告，以及額度重置回滿時通知",
                    isOn: $settings.notificationsEnabled
                )

                SettingsToggleRow(
                    title: "登入 macOS 時自動啟動",
                    subtitle: "無 Dock 圖示常駐狀態列",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.setEnabled(newValue)
                }
            }
        }
    }

    private var updateCard: some View {
        SettingsCard(title: "版本與 GitHub 更新", icon: "arrow.triangle.2.circlepath.circle.fill") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("UsageView v\(UpdateService.currentVersion)")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(statusDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
                Spacer()

                if case .available(let version, _, _) = updater.status {
                    Button {
                        Task { await updater.performUpdate() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("更新至 v\(version)")
                        }
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Color(red: 0.25, green: 0.78, blue: 0.52), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await updater.checkForUpdates() }
                    } label: {
                        HStack(spacing: 4) {
                            if updater.status == .checking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                            }
                            Text(updater.status == .checking ? "檢查中…" : "檢查更新")
                        }
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(updater.status == .checking)
                }
            }
        }
    }

    private var statusDescription: String {
        switch updater.status {
        case .idle: "來源：github.com/\(UpdateService.repo)"
        case .checking: "正在向 GitHub 查詢最新 Release…"
        case .upToDate(let msg): msg
        case .available(let v, let notes, _): "發現新版本 v\(v)（\(notes)）"
        case .updating(let msg): msg
        case .failed(let msg): msg
        }
    }

    private var statusColor: Color {
        switch updater.status {
        case .available: Color(red: 0.30, green: 0.88, blue: 0.56)
        case .failed: .orange
        default: .white.opacity(0.56)
        }
    }
}

// MARK: - Reusable Settings Components

private struct ModeSegmentedPicker: View {
    @Binding var selection: MultiProviderDisplayMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MultiProviderDisplayMode.allCases, id: \.self) { mode in
                let active = selection == mode
                Button {
                    selection = mode
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 9, weight: .bold))
                        Text(mode.title)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(active ? .white : .white.opacity(0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(active ? Color.white.opacity(0.20) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(title)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct PillToggleButton: View {
    let title: String
    let icon: String
    let isOn: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isOn ? .white : .white.opacity(0.42))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isOn ? accent.opacity(0.28) : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isOn ? accent.opacity(0.78) : Color.white.opacity(0.10), lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.50))
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isOn.toggle()
                }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color(red: 0.20, green: 0.78, blue: 0.48) : Color.white.opacity(0.14))
                        .frame(width: 32, height: 18)
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
