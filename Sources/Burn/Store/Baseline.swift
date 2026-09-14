import Foundation

/// What "usual" is for an account, derived from what Burn already keeps: the week of dense samples behind the
/// sparkline, and the per-day token totals from Claude Code's logs. A surge is the present measured against that —
/// a window burning at several times the typical busy hour, a model doing several times a typical day's work.
/// "Typical" is the 75th percentile of the active hours (or days): what a busy hour usually looks like, so the
/// light hours don't drag the norm down until every focused hour counts as a surge. Pure maths; nothing is stored.
enum Baseline {
    /// Where "typical" sits in the distribution of active hours or days.
    static let typicalPercentile = 0.75
    /// Hours of the dense week that count as "busy": at least this much of the window used in the hour.
    static func activeHour(kind: UsageWindow.Kind) -> Double {
        switch kind {
        case .session, .daily: 1
        default: 0.2
        }
    }

    /// Below this the rate is too small for a multiple of it to mean anything.
    static func rateFloor(kind: UsageWindow.Kind) -> Double {
        switch kind {
        case .session, .daily: 10
        case .weekly: 1.5
        default: 0.5
        }
    }

    static let minimumActiveHours = 10
    static let minimumActiveDays = 2
    /// A day counts as an active day of API work from this much; typical needs this many of them.
    static let activeDayDollars = 1.0
    static let minimumSpendDays = 5
    /// Today's API-priced work must reach this before a multiple of a typical day is worth a banner.
    static let modelSpendFloor = 20.0
    static let accountSpendFloor = 40.0

    /// Points of the window used in a typical busy hour, from the recorded readings (oldest first). Pairs across a
    /// gap or a reset are skipped; hours inside the pace lookback are left out so a surge can't set its own bar.
    static func typicalRate(points: [(t: Date, used: Double)], kind: UsageWindow.Kind, now: Date = .now) -> Double? {
        let start = now.addingTimeInterval(-History.denseFor)
        let recent = now.addingTimeInterval(-Pace.lookback(for: kind))
        var hours: [Int: Double] = [:]
        var previous: (t: Date, used: Double)?
        for point in points where point.t >= start && point.t <= now {
            defer { previous = point }
            guard let last = previous else { continue }
            let dt = point.t.timeIntervalSince(last.t)
            if dt <= 0 || dt > Pace.gap || last.used - point.used >= Pace.resetDrop { continue }
            let delta = max(0, point.used - last.used)
            guard delta > 0, point.t < recent else { continue }
            hours[Int(point.t.timeIntervalSince1970 / 3600), default: 0] += delta
        }
        let floor = activeHour(kind: kind)
        let active = hours.filter { $0.value >= floor }
        let days = Set(active.keys.map { $0 / 24 })
        guard active.count >= minimumActiveHours, days.count >= minimumActiveDays else { return nil }
        return percentile(Array(active.values), typicalPercentile)
    }

    /// A typical active day's dollars from per-day costs (`yyyy-MM-dd` → dollars), leaving today out.
    static func typicalDaily(costs: [String: Double], today: String) -> Double? {
        let active = costs.filter { $0.key != today && $0.value >= activeDayDollars }.map(\.value)
        guard active.count >= minimumSpendDays else { return nil }
        return percentile(active, typicalPercentile)
    }

    /// Nearest-rank percentile: the value `p` of the way up the sorted list.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
    }

    /// "3×", "2.6×", "12×".
    static func multipleText(_ multiple: Double) -> String {
        if multiple >= 10 { return "\(Int(multiple.rounded()))×" }
        let s = String(format: "%.1f", multiple)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "×"
    }
}
