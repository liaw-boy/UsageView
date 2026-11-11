import Foundation

/// One observation of a provider's primary 5H or 7D usage.
public struct QuotaSample: Codable, Sendable, Equatable {
    public let provider: ProviderID
    public let kind: WindowKind
    public let used: Double
    public let resetsAt: Date?
    public let at: Date

    public init(provider: ProviderID, kind: WindowKind, used: Double, resetsAt: Date?, at: Date) {
        self.provider = provider
        self.kind = kind
        self.used = used
        self.resetsAt = resetsAt
        self.at = at
    }
}

/// Highest usage seen inside one quota window (identified by its reset time).
public struct WindowPeak: Sendable, Equatable, Identifiable {
    public var id: Date { resetsAt }
    public let resetsAt: Date
    public let peak: Double
}

/// Local-only history of quota percentages, so the statistics page can draw how usage moved and how much of each
/// window was used before it reset. Kept 30 days; nothing here is ever sent anywhere.
@MainActor
public final class QuotaHistoryStore {
    public static let retention: TimeInterval = 30 * 86_400
    /// An unchanged value is still recorded this often, so the chart shows flat stretches instead of gaps.
    static let heartbeat: TimeInterval = 30 * 60

    public private(set) var samples: [QuotaSample] = []
    private let url: URL

    /// Decodes one array element without failing the whole file (e.g. a provider added by a newer version).
    private struct Lossy: Decodable {
        let sample: QuotaSample?
        init(from decoder: Decoder) throws { sample = try? QuotaSample(from: decoder) }
    }

    public init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let items = try? decoder.decode([Lossy].self, from: data) {
            samples = items.compactMap(\.sample)
        } else {
            // Unreadable file: keep it aside instead of letting the next save overwrite the history.
            // One fixed name, so repeated corruption never piles up copies.
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    /// Records the snapshot's primary 5H / 7D values when they changed (or the heartbeat elapsed). Returns true if stored.
    @discardableResult
    public func record(_ snap: ProviderSnapshot, now: Date = Date()) -> Bool {
        var changed = false
        for kind in [WindowKind.session, .weekly] {
            guard let line = snap.primaryLine(kind) else { continue }
            let used = line.usedPercent, reset = line.resetsAt
            let last = samples.last { $0.provider == snap.provider && $0.kind == kind }
            if let last, abs(last.used - used) < 0.5, Self.sameWindow(last.resetsAt, reset),
               now.timeIntervalSince(last.at) < Self.heartbeat {
                continue
            }
            samples.append(QuotaSample(provider: snap.provider, kind: kind, used: used, resetsAt: reset, at: now))
            changed = true
        }
        guard changed else { return false }
        samples.removeAll { now.timeIntervalSince($0.at) > Self.retention }
        save()
        return true
    }

    public func series(_ provider: ProviderID, _ kind: WindowKind, since: Date) -> [QuotaSample] {
        samples.filter { $0.provider == provider && $0.kind == kind && $0.at >= since }
    }

    /// Peak usage per window, newest first. Reset times jitter by seconds between reads, so resets within the same
    /// tolerance as `sameWindow` are one window.
    nonisolated public static func windowPeaks(_ samples: [QuotaSample]) -> [WindowPeak] {
        let timed = samples.compactMap { s in s.resetsAt.map { ($0, s.used) } }.sorted { $0.0 < $1.0 }
        var out: [WindowPeak] = []
        for (reset, used) in timed {
            if let last = out.last, sameWindow(last.resetsAt, reset) {
                out[out.count - 1] = WindowPeak(resetsAt: reset, peak: max(last.peak, used))
            } else {
                out.append(WindowPeak(resetsAt: reset, peak: used))
            }
        }
        return out.reversed()
    }

    nonisolated static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 600
        default: false
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? encoder.encode(samples).write(to: url, options: .atomic)
    }
}

/// Headline numbers for the statistics page, derived from the daily history.
public struct UsageInsights: Sendable, Equatable {
    public let peakDay: DailyUsageItem?
    /// Consecutive days with usage, ending today (or yesterday when today has nothing yet).
    public let streakDays: Int
    public let activeDays: Int
    public let monthToDateUSD: Double
    /// Month-to-date plus the last 7 days' daily average for every remaining day of the calendar month.
    public let projectedMonthUSD: Double

    public static func compute(daily: [DailyUsageItem], now: Date = Date(), calendar cal: Calendar = .current) -> UsageInsights {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let byDate = Dictionary(daily.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> DailyUsageItem? {
            cal.date(byAdding: .day, value: -offset, to: today).flatMap { byDate[f.string(from: $0)] }
        }

        var streak = 0
        var offset = (day(0)?.tokens ?? 0) > 0 ? 0 : 1
        while (day(offset)?.tokens ?? 0) > 0 { streak += 1; offset += 1 }

        let monthPrefix = String(f.string(from: today).prefix(8)) // "yyyy-MM-"
        let mtd = daily.filter { $0.date.hasPrefix(monthPrefix) }.reduce(0) { $0 + $1.costUSD }
        let last7 = (0..<7).compactMap { day($0)?.costUSD }.reduce(0, +) / 7
        let daysInMonth = cal.range(of: .day, in: .month, for: today)?.count ?? 30
        let remaining = max(0, daysInMonth - cal.component(.day, from: today))

        return UsageInsights(
            peakDay: daily.filter { $0.tokens > 0 }.max { ($0.costUSD, $0.tokens) < ($1.costUSD, $1.tokens) },
            streakDays: streak,
            activeDays: daily.filter { $0.tokens > 0 }.count,
            monthToDateUSD: mtd,
            projectedMonthUSD: mtd + last7 * Double(remaining)
        )
    }
}
