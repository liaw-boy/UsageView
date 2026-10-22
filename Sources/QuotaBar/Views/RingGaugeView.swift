import QuotaBarCore
import SwiftUI

// MARK: - Brand Palette & Status Colors

enum Theme {
    static func brandColor(_ id: ProviderID) -> Color {
        switch id {
        case .claude: Color(red: 0.95, green: 0.52, blue: 0.38)      // Warm Coral
        case .codex: Color(red: 0.28, green: 0.85, blue: 0.72)       // Mint Teal
        case .antigravity: Color(red: 0.48, green: 0.42, blue: 0.98) // Electric Indigo
        }
    }

    static let antigravitySecondary = Color(red: 0.72, green: 0.44, blue: 0.98) // Violet for 3p pool

    /// Overrides the brand accent with Amber (>80%) or Crimson (>95%) when quota runs hot.
    static func ringColor(for id: ProviderID, usedPercent: Double, secondaryPool: Bool = false) -> Color {
        if usedPercent >= 95 { return Color(red: 0.98, green: 0.28, blue: 0.36) }
        if usedPercent >= 80 { return Color(red: 0.98, green: 0.72, blue: 0.22) }
        if id == .antigravity && secondaryPool { return antigravitySecondary }
        return brandColor(id)
    }

    static func formattedPercent(_ used: Double, showRemaining: Bool) -> String {
        let val = showRemaining ? max(0, 100 - used) : used
        return "\(Int(val.rounded()))%"
    }
}

// MARK: - Concentric Dual-Ring Gauge

/// Outer ring = 5-hour session window; Inner ring = weekly window.
/// For Antigravity, the outer and inner rings split into two 170° arcs (Gemini vs Claude/GPT pools).
struct DualRingGauge: View {
    let provider: ProviderID
    let lines: [MetricLine]
    let showRemaining: Bool
    var size: CGFloat = 68
    var lineWidth: CGFloat = 6.5

    private var sessionUsed: Double {
        lines.filter { $0.kind == .session }.map(\.usedPercent).max() ?? 0
    }

    private var weeklyUsed: Double {
        lines.filter { $0.kind == .weekly }.map(\.usedPercent).max() ?? 0
    }

    var body: some View {
        ZStack {
            if provider == .antigravity, hasSplitPools {
                splitRing(kind: .session, inset: 0)
                splitRing(kind: .weekly, inset: lineWidth + 3.5)
            } else {
                singleRing(used: sessionUsed, inset: 0)
                singleRing(used: weeklyUsed, inset: lineWidth + 3.5)
            }

            if size >= 50 {
                VStack(spacing: -1) {
                    Text(Theme.formattedPercent(sessionUsed, showRemaining: showRemaining))
                        .font(.system(size: size * 0.23, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(showRemaining ? "剩餘" : "5h")
                        .font(.system(size: size * 0.13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: sessionUsed)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: weeklyUsed)
    }

    private var hasSplitPools: Bool {
        lines.contains { $0.pool == "gemini" } && lines.contains { $0.pool == "3p" }
    }

    @ViewBuilder
    private func singleRing(used: Double, inset: CGFloat) -> some View {
        let color = Theme.ringColor(for: provider, usedPercent: used)
        let progress = min(max(used / 100, 0.005), 1)
        ZStack {
            Circle()
                .inset(by: inset + lineWidth / 2)
                .stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    @ViewBuilder
    private func splitRing(kind: WindowKind, inset: CGFloat) -> some View {
        let geminiUsed = lines.first { $0.kind == kind && $0.pool == "gemini" }?.usedPercent ?? 0
        let thirdPartyUsed = lines.first { $0.kind == kind && $0.pool == "3p" }?.usedPercent ?? 0
        let c1 = Theme.ringColor(for: .antigravity, usedPercent: geminiUsed, secondaryPool: false)
        let c2 = Theme.ringColor(for: .antigravity, usedPercent: thirdPartyUsed, secondaryPool: true)

        ZStack {
            // Left half: Gemini (0...0.46)
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.02, to: 0.48)
                .stroke(c1.opacity(0.18), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.02, to: 0.02 + 0.46 * min(max(geminiUsed / 100, 0.01), 1))
                .stroke(c1, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Right half: Claude/GPT (0.52...0.98)
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.52, to: 0.98)
                .stroke(c2.opacity(0.18), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.52, to: 0.52 + 0.46 * min(max(thirdPartyUsed / 100, 0.01), 1))
                .stroke(c2, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Menu Bar Strip

struct MenuBarStripView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore

    private var activeItems: [(ProviderID, ProviderSnapshot)] {
        let all = store.enabledProviders.compactMap { id -> (ProviderID, ProviderSnapshot)? in
            guard let snap = store.states[id]?.snapshot, !snap.lines.isEmpty else { return nil }
            return (id, snap)
        }
        switch settings.menuBarMode {
        case .all:
            return all
        case .tightest:
            return all.max { ($0.1.sessionPercent ?? 0) < ($1.1.sessionPercent ?? 0) }.map { [$0] } ?? []
        case .iconOnly:
            return []
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if activeItems.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 12, weight: .semibold))
                    if settings.menuBarMode != .iconOnly {
                        Text("QuotaBar")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                }
            } else {
                ForEach(activeItems, id: \.0) { id, snap in
                    HStack(spacing: 4) {
                        DualRingGauge(
                            provider: id,
                            lines: snap.lines,
                            showRemaining: settings.showRemaining,
                            size: 15,
                            lineWidth: 2.0
                        )
                        if let p = snap.sessionPercent {
                            Text("\(id.shortName) \(Theme.formattedPercent(p, showRemaining: settings.showRemaining))")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}
