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
                header
                if controller.showingSettings {
                    SettingsView(settings: settings, updater: updater)
                } else {
                    cardsContent
                }
                footer
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 368)
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
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("v\(UpdateService.currentVersion)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08), in: Capsule())

                    if case .available(let newVer, _, _) = updater.status {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                controller.showingSettings = true
                            }
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
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.54))
            }

            Spacer()

            Button {
                settings.showRemaining.toggle()
            } label: {
                Text(settings.showRemaining ? "剩餘 %" : "已用 %")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
                    .padding(.horizontal, 8)
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
                    .frame(width: 24, height: 24)
                    .background(Theme.cardBackground, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("立即重新整理")
        }
    }

    private var updatedSubtitle: String {
        guard let date = store.lastUpdated else { return "唯讀查詢 · 每 \(settings.refreshMinutes) 分鐘自動更新" }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 30 { return "剛剛更新 · 每 \(settings.refreshMinutes)m 自動同步" }
        if secs < 3600 { return "更新於 \(secs / 60) 分鐘前 · 每 \(settings.refreshMinutes)m 自動同步" }
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
                    withAnimation(.easeInOut(duration: 0.16)) { controller.showingSettings = true }
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
                        onToggleMode: { settings.showRemaining.toggle() }
                    )
                }
            }
        }
    }

    // MARK: - Compact Footer

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    controller.showingSettings.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: controller.showingSettings ? "chevron.left" : "slider.horizontal.3")
                    Text(controller.showingSettings ? "返回額度面板" : "設定與更新")
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Button("結束") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
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

    @State private var isHovered = false

    private var lines: [MetricLine] { state.snapshot?.lines ?? [] }

    private var headlinePace: Pace? {
        lines.first(where: { $0.kind == .session })?.pace ?? lines.first?.pace
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            DualRingGauge(provider: provider, lines: lines, showRemaining: showRemaining, size: 56, lineWidth: 5.5)
                .opacity(state.isStale ? 0.65 : 1.0)
                .onTapGesture(perform: onToggleMode)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProviderLogoView(provider: provider, size: 13.5, tinted: true)
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    if let error = state.error, state.snapshot != nil {
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
                        .help("官方 API 暫時冷卻中，目前顯示上次成功同步的快取資料（\(error)）")
                    }

                    Spacer()

                    if let pace = headlinePace {
                        PaceChip(pace: pace)
                    }
                }

                if lines.isEmpty {
                    if let error = state.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
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
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.35))
                    .frame(width: fillWidth)

                HStack(spacing: 4) {
                    Text(line.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text(trailingText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(.horizontal, 7)
            }
        }
        .frame(height: 19)
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
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
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

                Divider().overlay(Color.white.opacity(0.08))

                SettingsToggleRow(
                    title: "用量超過 80% / 95% 時發送通知",
                    subtitle: "每個重設週期只提醒一次",
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
