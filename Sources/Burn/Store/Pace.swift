import Foundation

/// How fast a pooled window is being used and where that leads: a rate from the recent samples, the time it runs
/// out at that rate, and where the window "should" be if usage were spread evenly across it. Pure maths over the
/// history the store already keeps, recomputed after every refresh — nothing new is stored.
struct Pace: Sendable, Hashable, Codable {
    enum Verdict: String, Sendable, Codable {
        /// Fewer than three samples over fifteen minutes since the last reset — nothing to say yet.
        case early
        /// At this rate the window lasts until its reset, or there is no reset to beat.
        case onPace
        /// At this rate it runs out before the reset, by more than the margin.
        case fast
        /// Nothing used lately.
        case stalled
    }

    /// Points of the window per hour.
    var rate: Double
    /// When the window reaches 100 % at this rate; nil when nothing is being used.
    var runOut: Date?
    /// Where the window would be now if usage were spread evenly from its start to its reset; nil without a length.
    var expectedNow: Double?
    var verdict: Verdict
    /// How much earlier than the reset it runs out, when `fast`.
    var shortfall: TimeInterval?
    /// Points per hour in a typical busy hour for this account and window (`Baseline`); nil until there is a week
    /// of history to say. Absent in files written by older builds.
    var typical: Double?

    /// The current rate as a multiple of the typical one — 3.0 means three times the usual burn.
    var multiple: Double? {
        guard let typical, typical > 0, rate > 0 else { return nil }
        return rate / typical
    }

    /// "28 %/h · 9 %/h usual".
    var rateVsTypicalText: String {
        guard let typical else { return rateText }
        return "\(rateText) · \(Pace(rate: typical, runOut: nil, expectedNow: nil, verdict: .onPace, shortfall: nil).rateText) usual"
    }

    static let minimumSamples = 3
    static let minimumSpan: TimeInterval = 15 * 60
    /// A gap this long between samples (the Mac was asleep) starts the run again.
    static let gap: TimeInterval = 20 * 60
    /// A drop this large between consecutive samples is a reset; only what came after it counts.
    static let resetDrop: Double = 20

    /// How far back to look: an hour for the short windows, six for the slow ones.
    static func lookback(for kind: UsageWindow.Kind) -> TimeInterval {
        switch kind {
        case .session, .daily: 3600
        case .weekly, .monthly, .model, .spend: 6 * 3600
        }
    }

    /// What separates "fast" from "on pace": a tenth of the window, never less than half an hour.
    static func margin(windowSeconds: Int?) -> TimeInterval {
        max(30 * 60, Double(windowSeconds ?? 0) * 0.1)
    }

    /// `points` are the window's recorded readings, oldest first; `window` carries the current reading and reset.
    static func compute(points: [(t: Date, used: Double)], window: UsageWindow, now: Date = .now) -> Pace {
        let cutoff = now.addingTimeInterval(-lookback(for: window.kind))
        var run: [(t: Date, used: Double)] = []
        for point in points where point.t >= cutoff && point.t <= now {
            if let last = run.last, last.used - point.used >= resetDrop || point.t.timeIntervalSince(last.t) > gap {
                run.removeAll()
            }
            run.append(point)
        }
        let expected = expectedNow(window: window, now: now)
        guard run.count >= minimumSamples, let first = run.first, let last = run.last,
              last.t.timeIntervalSince(first.t) >= minimumSpan else {
            return Pace(rate: 0, runOut: nil, expectedNow: expected, verdict: .early, shortfall: nil)
        }
        let rate = max(0, slope(run) * 3600)
        guard rate > 0.05 else {
            return Pace(rate: 0, runOut: nil, expectedNow: expected, verdict: .stalled, shortfall: nil)
        }
        let runOut = now.addingTimeInterval(max(0, 100 - window.usedPercent) / rate * 3600)
        var verdict = Verdict.onPace
        var shortfall: TimeInterval?
        if let reset = window.resetsAt {
            let early = reset.timeIntervalSince(runOut)
            if early > margin(windowSeconds: window.windowSeconds) {
                verdict = .fast
                shortfall = early
            }
        }
        return Pace(rate: rate, runOut: runOut, expectedNow: expected, verdict: verdict, shortfall: shortfall)
    }

    static func expectedNow(window: UsageWindow, now: Date) -> Double? {
        guard let reset = window.resetsAt, let length = window.windowSeconds, length > 0 else { return nil }
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-Double(length)))
        guard elapsed >= 0 else { return nil }
        return min(100, elapsed / Double(length) * 100)
    }

    /// "2.6 %/h", "12 %/h".
    var rateText: String {
        rate < 10 ? String(format: "%.1f %%/h", rate) : "\(Int(rate.rounded())) %/h"
    }

    /// Least-squares slope of used % against seconds.
    private static func slope(_ run: [(t: Date, used: Double)]) -> Double {
        let n = Double(run.count)
        let t0 = run[0].t
        let xs = run.map { $0.t.timeIntervalSince(t0) }
        let ys = run.map(\.used)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - mx) * (y - my)
            den += (x - mx) * (x - mx)
        }
        return den > 0 ? num / den : 0
    }
}
