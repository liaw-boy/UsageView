import AppKit
import QuotaBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: UpdateService
    @ObservedObject var controller: StatusItemController

    var body: some View {
        ZStack {
            PanelBackdrop()
            VStack(spacing: 12) {
                header
                if controller.showingSettings {
                    SettingsView(settings: settings, updater: updater)
                } else {
                    cardsList
                }
                footer
            }
            .padding(16)
        }
        .frame(width: 368)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(controller.showingSettings ? "偏好設定" : "QuotaBar")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if controller.showingSettings {
                        Text("v\(UpdateService.currentVersion)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.10), in: Capsule())
                    }
                }
                if let date = store.lastUpdated {
                    Text("更新於 \(date, style: .relative)前 · 唯讀不耗額度")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.58))
                } else {
                    Text("唯讀查詢 · 零額度消耗")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            Spacer()
            Button {
                settings.showRemaining.toggle()
            } label: {
                Text(settings.showRemaining ? "顯示：剩餘" : "顯示：已用")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("點擊切換「已用 %」與「剩餘 %」")

            Button {
                Task { await store.refresh(manual: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: store.isRefreshing
                    )
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("立即重新整理（30 秒節流保護）")
        }
    }

    @ViewBuilder
    private var cardsList: some View {
        let visible = store.panelProviders
        if visible.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.45))
                Text("目前未勾選任何面板顯示服務")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Button("前往設定調整") {
                    withAnimation(.easeInOut(duration: 0.18)) { controller.showingSettings = true }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(red: 0.52, green: 0.65, blue: 1.0))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.10), in: Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(red: 0.14, green: 0.16, blue: 0.23).opacity(0.92))
            )
        } else {
            VStack(spacing: 10) {
                ForEach(visible) { id in
                    ProviderCardView(
                        provider: id,
                        state: store.states[id] ?? ProviderState(),
                        showRemaining: settings.showRemaining,
                        onToggleMode: { settings.showRemaining.toggle() }
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controller.showingSettings.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: controller.showingSettings ? "chevron.left" : "slider.horizontal.3")
                    Text(controller.showingSettings ? "返回額度面板" : "設定與更新")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button("結束") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.top, 2)
    }
}

// MARK: - Provider Card

struct ProviderCardView: View {
    let provider: ProviderID
    let state: ProviderState
    let showRemaining: Bool
    let onToggleMode: () -> Void

    @State private var isHovered = false

    private var lines: [MetricLine] { state.snapshot?.lines ?? [] }

    private var headlinePace: Pace? {
        lines.first(where: { $0.kind == .session })?.pace ?? lines.first?.pace
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DualRingGauge(provider: provider, lines: lines, showRemaining: showRemaining)
                .opacity(state.isStale ? 0.55 : 1.0)
                .onTapGesture(perform: onToggleMode)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.brandColor(provider))
                        .frame(width: 7, height: 7)
                    Text(provider.displayName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    if let error = state.error, state.snapshot != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .help("更新失敗（顯示上次資料）：\(error)")
                    }

                    Spacer()

                    if let pace = headlinePace {
                        PaceChip(pace: pace)
                    }
                }

                if lines.isEmpty {
                    if let error = state.error {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else {
                        Text(state.isRefreshing ? "讀取中…" : "No data")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else {
                    VStack(spacing: 5) {
                        ForEach(lines) { line in
                            MetricBarRow(
                                provider: provider,
                                line: line,
                                showRemaining: showRemaining,
                                showDetail: isHovered
                            )
                        }
                    }
                    .opacity(state.isStale ? 0.65 : 1.0)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(red: 0.14, green: 0.16, blue: 0.23).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Theme.brandColor(provider).opacity(isHovered ? 0.55 : 0.25), lineWidth: 1)
                )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

private struct MetricBarRow: View {
    let provider: ProviderID
    let line: MetricLine
    let showRemaining: Bool
    let showDetail: Bool

    private var color: Color {
        Theme.ringColor(for: provider, usedPercent: line.usedPercent, secondaryPool: line.pool == "3p")
    }

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(4, geo.size.width * CGFloat(line.usedPercent / 100))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.38))
                    .frame(width: fillWidth)

                HStack(spacing: 4) {
                    Text(line.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text(trailingText)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 22)
    }

    private var trailingText: String {
        let pct = Theme.formattedPercent(line.usedPercent, showRemaining: showRemaining)
        if line.isNotStarted { return "\(pct) · Not started" }
        guard let reset = line.resetsAt else { return pct }
        if showDetail {
            let f = DateFormatter()
            f.dateFormat = "E HH:mm"
            return "\(pct) · 重設 \(f.string(from: reset))"
        }
        let secs = max(0, Int(reset.timeIntervalSinceNow))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let rel = h >= 24 ? "\(h / 24)d \(h % 24)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
        return "\(pct) · \(rel)"
    }
}

private struct PaceChip: View {
    let pace: Pace

    private var label: String {
        switch pace {
        case .relaxed: "悠閒"
        case .onTrack: "剛好"
        case .fast: "燒很快"
        }
    }

    private var tint: Color {
        switch pace {
        case .relaxed: Color(red: 0.30, green: 0.88, blue: 0.56)
        case .onTrack: Color(red: 0.45, green: 0.72, blue: 1.00)
        case .fast: Color(red: 1.00, green: 0.68, blue: 0.24)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.20), in: Capsule())
    }
}

// MARK: - Redesigned Settings View (Cohesive Dark Cards)

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: UpdateService
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 10) {
            providerMatrixCard
            scheduleAndAlertsCard
            updateCard
        }
    }

    // 1. 三層獨立控制矩陣：啟動追蹤 / 面板顯示 / 狀態列顯示
    private var providerMatrixCard: some View {
        SettingsCard(title: "服務追蹤與顯示位置", icon: "square.stack.3d.up.fill") {
            VStack(spacing: 8) {
                HStack {
                    Text("服務名稱")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text("啟動追蹤 / 展開面板 / 狀態列")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.bottom, 2)

                ForEach(ProviderID.allCases) { id in
                    let tracked = settings.isTracked(id)
                    let inPanel = settings.isShownInPanel(id)
                    let inBar = settings.isShownInMenuBar(id)
                    let accent = Theme.brandColor(id)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                            .opacity(tracked ? 1.0 : 0.35)
                        Text(id.displayName)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
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
                    .padding(.vertical, 3)
                }

                Divider().overlay(Color.white.opacity(0.10))

                SettingsToggleRow(
                    title: "狀態列自動只顯示最緊張的一家",
                    subtitle: "勾選多家時，狀態列僅保留 5h 用量最高者",
                    isOn: $settings.menuBarOnlyTightest
                )
            }
        }
    }

    // 2. 更新頻率與提醒設定
    private var scheduleAndAlertsCard: some View {
        SettingsCard(title: "更新頻率與提醒", icon: "bell.badge.fill") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("背景自動更新間隔")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Text("每 \(settings.refreshMinutes) 分鐘")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.52, green: 0.68, blue: 1.0))
                    }
                    HStack(spacing: 6) {
                        ForEach(SettingsStore.refreshOptions, id: \.self) { m in
                            let selected = settings.refreshMinutes == m
                            Button {
                                settings.refreshMinutes = m
                            } label: {
                                Text("\(m)m")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .foregroundStyle(selected ? .white : .white.opacity(0.62))
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(selected ? Color(red: 0.44, green: 0.42, blue: 0.96) : Color.white.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().overlay(Color.white.opacity(0.10))

                SettingsToggleRow(
                    title: "用量超過 80% / 95% 時發送通知",
                    subtitle: "每個重設週期只會提醒一次",
                    isOn: $settings.notificationsEnabled
                )

                SettingsToggleRow(
                    title: "登入 macOS 時自動啟動",
                    subtitle: "以無 Dock 圖示背景常駐狀態列",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.setEnabled(newValue)
                }
            }
        }
    }

    // 3. GitHub 自動檢查與更新
    private var updateCard: some View {
        SettingsCard(title: "版本與 GitHub 更新", icon: "arrow.triangle.2.circlepath.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("目前版本 v\(UpdateService.currentVersion)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(statusDescription)
                            .font(.system(size: 10.5))
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
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
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
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .disabled(updater.status == .checking)
                    }
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
        default: .white.opacity(0.58)
        }
    }
}

// MARK: - Reusable Settings Components

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.56, green: 0.64, blue: 1.0))
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(red: 0.14, green: 0.16, blue: 0.23).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
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
            HStack(spacing: 3.5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isOn ? .white : .white.opacity(0.42))
            .padding(.horizontal, 7.5)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? accent.opacity(0.32) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isOn ? accent.opacity(0.85) : Color.white.opacity(0.10), lineWidth: 0.9)
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
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.50))
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

// MARK: - Rich Opaque Navy-Indigo Backdrop

struct PanelBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.09, blue: 0.14).opacity(0.98),
                Color(red: 0.11, green: 0.10, blue: 0.19).opacity(0.98),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
