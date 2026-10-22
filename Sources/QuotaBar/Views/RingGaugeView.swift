import QuotaBarCore
import SwiftUI

// MARK: - Brand Palette & Status Colors

enum Theme {
    static func brandColor(_ id: ProviderID) -> Color {
        switch id {
        case .claude: Color(red: 0.96, green: 0.55, blue: 0.40)      // Warm Coral
        case .codex: Color(red: 0.30, green: 0.88, blue: 0.74)       // Mint Teal
        case .antigravity: Color(red: 0.52, green: 0.46, blue: 1.00) // Electric Indigo
        }
    }

    static let antigravitySecondary = Color(red: 0.76, green: 0.48, blue: 1.00) // Violet for 3p pool

    /// Overrides the brand accent with Amber (>80%) or Crimson (>95%) when quota runs hot.
    static func ringColor(for id: ProviderID, usedPercent: Double, secondaryPool: Bool = false) -> Color {
        if usedPercent >= 95 { return Color(red: 1.00, green: 0.32, blue: 0.38) }
        if usedPercent >= 80 { return Color(red: 1.00, green: 0.75, blue: 0.24) }
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
/// For Antigravity, the outer and inner rings split into two arcs (Gemini vs Claude/GPT pools).
struct DualRingGauge: View {
    let provider: ProviderID
    let lines: [MetricLine]
    let showRemaining: Bool
    var size: CGFloat = 58
    var lineWidth: CGFloat = 5.8

    private var sessionUsed: Double {
        lines.filter { $0.kind == .session }.map(\.usedPercent).max() ?? 0
    }

    private var weeklyUsed: Double {
        lines.filter { $0.kind == .weekly }.map(\.usedPercent).max() ?? 0
    }

    private var innerInset: CGFloat {
        size < 24 ? (lineWidth + 1.2) : (lineWidth + 3.0)
    }

    var body: some View {
        ZStack {
            if provider == .antigravity, hasSplitPools {
                splitRing(kind: .session, inset: 0)
                if size >= 24 {
                    splitRing(kind: .weekly, inset: innerInset)
                }
            } else {
                singleRing(used: sessionUsed, inset: 0)
                if size >= 24 {
                    singleRing(used: weeklyUsed, inset: innerInset)
                }
            }

            if size >= 46 {
                VStack(spacing: -1) {
                    Text(Theme.formattedPercent(sessionUsed, showRemaining: showRemaining))
                        .font(.system(size: size * 0.23, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text(showRemaining ? "剩餘" : "5h")
                        .font(.system(size: size * 0.13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
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
                .stroke(color.opacity(0.25), lineWidth: lineWidth)
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
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.03, to: 0.47)
                .stroke(c1.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.03, to: 0.03 + 0.44 * min(max(geminiUsed / 100, 0.01), 1))
                .stroke(c1, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.53, to: 0.97)
                .stroke(c2.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .inset(by: inset + lineWidth / 2)
                .trim(from: 0.53, to: 0.53 + 0.44 * min(max(thirdPartyUsed / 100, 0.01), 1))
                .stroke(c2, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Menu Bar Strip

struct MenuBarStripView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore

    private static let pillFill = Color(red: 0.11, green: 0.12, blue: 0.17).opacity(0.94)
    private static let pillStroke = Color.white.opacity(0.22)

    private var activeItems: [(ProviderID, ProviderSnapshot)] {
        let candidates = store.menuBarProviders.compactMap { id -> (ProviderID, ProviderSnapshot)? in
            guard let snap = store.states[id]?.snapshot, !snap.lines.isEmpty else { return nil }
            return (id, snap)
        }
        guard !candidates.isEmpty else { return [] }

        switch settings.menuBarDisplayMode {
        case .all:
            return candidates
        case .single:
            if let match = candidates.first(where: { $0.0 == settings.selectedSingleProvider }) {
                return [match]
            }
            return candidates.max { ($0.1.sessionPercent ?? 0) < ($1.1.sessionPercent ?? 0) }.map { [$0] } ?? []
        case .carousel:
            let idx = abs(store.carouselTick) % candidates.count
            return [candidates[idx]]
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if activeItems.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    if !store.menuBarProviders.isEmpty {
                        Text("TokenPulse")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Self.pillFill, in: Capsule())
                .overlay(Capsule().strokeBorder(Self.pillStroke, lineWidth: 0.8))
            } else {
                ForEach(activeItems, id: \.0) { id, snap in
                    HStack(spacing: 4) {
                        DualRingGauge(
                            provider: id,
                            lines: snap.lines,
                            showRemaining: settings.showRemaining,
                            size: 13,
                            lineWidth: 2.2
                        )
                        if let p = snap.sessionPercent {
                            Text("\(id.shortName) \(Theme.formattedPercent(p, showRemaining: settings.showRemaining))")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(Self.pillFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Self.pillStroke, lineWidth: 0.8))
                }
            }
        }
        .padding(.horizontal, 2)
        .environment(\.colorScheme, .dark)
    }
}
