import AppKit
import QuotaBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: StatusItemController

    var body: some View {
        ZStack {
            PanelBackdrop()
            VStack(spacing: 12) {
                header
                if controller.showingSettings {
                    SettingsView(settings: settings, onDone: { controller.showingSettings = false })
                } else {
                    cardsList
                }
                footer
            }
            .padding(16)
        }
        .frame(width: 356)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("QuotaBar")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let date = store.lastUpdated {
                    Text("更新於 \(date, style: .relative)前")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                } else {
                    Text("唯讀查詢 · 零額度消耗")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            Spacer()
            Button {
                settings.showRemaining.toggle()
            } label: {
                Text(settings.showRemaining ? "顯示：剩餘" : "顯示：已用")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("點擊切換「已用 %」與「剩餘 %」")

            Button {
                Task { await store.refresh(manual: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: store.isRefreshing
                    )
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("立即重新整理（30 秒節流保護）")
        }
    }

    private var cardsList: some View {
        VStack(spacing: 10) {
            ForEach(store.enabledProviders) { id in
                ProviderCardView(
                    provider: id,
                    state: store.states[id] ?? ProviderState(),
                    showRemaining: settings.showRemaining,
                    onToggleMode: { settings.showRemaining.toggle() }
                )
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
                Label(controller.showingSettings ? "返回面板" : "設定", systemImage: controller.showingSettings ? "chevron.left" : "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))

            Spacer()

            Button("結束") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
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

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let onDone: () -> Void
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("狀態列樣式") {
                Picker("模式", selection: $settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases, id: \.self) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(4)
            }

            GroupBox("啟用的服務") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ProviderID.allCases) { id in
                        Toggle(isOn: Binding(
                            get: { settings.isEnabled(id) },
                            set: { settings.setEnabled(id, $0) }
                        )) {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.brandColor(id)).frame(width: 8, height: 8)
                                Text(id.displayName).foregroundStyle(.white)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("更新與提醒") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("自動更新間隔").foregroundStyle(.white)
                        Spacer()
                        Picker("", selection: $settings.refreshMinutes) {
                            ForEach(SettingsStore.refreshOptions, id: \.self) { m in
                                Text("\(m) 分鐘").tag(m)
                            }
                        }
                        .frame(width: 110)
                    }
                    Toggle("超過 80% / 95% 時發送通知", isOn: $settings.notificationsEnabled)
                    Toggle("登入時自動啟動", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            LaunchAtLogin.setEnabled(newValue)
                        }
                }
                .padding(4)
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - Rich Opaque Navy-Indigo Backdrop

struct PanelBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.09, blue: 0.14).opacity(0.97),
                Color(red: 0.11, green: 0.10, blue: 0.19).opacity(0.97),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
