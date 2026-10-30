import Charts
import SwiftUI

/// The session ring. The track is the design's recessed well; the fill carries severity; the number inside is ink,
/// never the data colour.
struct RingGauge: View {
    var usedPercent: Double
    var tone: Theme.Tone
    var diameter: CGFloat = 44
    var lineWidth: CGFloat = 5

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated: Double = 0

    var body: some View {
        let p = Palette.resolve(scheme)
        ZStack {
            Circle()
                .stroke(p.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, animated / 100)))
                .stroke(tone.mark(p), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                Text("\(Int(usedPercent.rounded()))")
                    .font(.system(size: diameter * 0.3, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(p.ink)
                Text("%")
                    .font(.system(size: diameter * 0.17, weight: .medium, design: .rounded))
                    .foregroundStyle(p.muted)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { animated = usedPercent } }
        .onChange(of: usedPercent) { _, new in withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { animated = new } }
        .accessibilityLabel("\(Int(usedPercent.rounded())) percent used")
    }
}

/// A window as two marks in one 8 pt lane: solid to what is used now, hatched on to where this pace lands by the
/// reset. Hatching that would run past the end stops there behind a red cap — the window won't last. Colours follow
/// the usual thresholds: the solid part by where it is, the hatching by where it lands.
struct ForecastBar: View {
    var usedPercent: Double
    /// From `Pace.forecast`; nil draws the solid part alone.
    var forecast: Double?
    var stale: Bool = false
    var height: CGFloat = 8

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownUsed: Double = 0
    @State private var shownLanding: Double = 0

    private var over: Bool { (forecast ?? 0) > 100 }
    private var landing: Double { max(usedPercent, min(100, forecast ?? usedPercent)) }

    var body: some View {
        let p = Palette.resolve(scheme)
        let usedTone = Theme.tone(forUsedPercent: usedPercent, stale: stale)
        let landingTone = over ? Theme.Tone.critical : Theme.tone(forUsedPercent: landing, stale: stale)
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(p.lane)
                Hatch(color: landingTone.mark(p))
                    .opacity(0.8)
                    .frame(width: max(0, width * (shownLanding - shownUsed) / 100))
                    .offset(x: width * shownUsed / 100)
                Rectangle()
                    .fill(usedTone.mark(p))
                    .frame(width: width * min(100, shownUsed) / 100)
                if over {
                    Rectangle()
                        .fill(p.markCritical)
                        .frame(width: 3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) { shownUsed = usedPercent; shownLanding = landing }
        }
        .onChange(of: usedPercent) { _, _ in withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { shownUsed = usedPercent; shownLanding = landing } }
        .onChange(of: forecast) { _, _ in withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { shownLanding = landing } }
        .accessibilityElement()
        .accessibilityLabel("\(Int(usedPercent.rounded())) percent used" + (forecast.map { over ? ", runs out before the reset" : ", \(Int($0.rounded())) by the reset" } ?? ""))
    }
}

/// Diagonal stripes, the forecast's mark: 2 pt lines every 4.5 pt, rising to the right.
struct Hatch: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let step = 4.5 * 2.squareRoot(), thickness = 2 * 2.squareRoot(), h = size.height
            var path = Path()
            var x = -h
            while x < size.width {
                path.move(to: CGPoint(x: x, y: h))
                path.addLine(to: CGPoint(x: x + thickness, y: h))
                path.addLine(to: CGPoint(x: x + thickness + h, y: 0))
                path.addLine(to: CGPoint(x: x + h, y: 0))
                path.closeSubpath()
                x += step
            }
            context.fill(path, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// A window's history as a line: the short window in ink, the long one muted, a dashed rule where "nearly out"
/// begins. Series identity is line weight and the legend, never the status colours — those mean one thing.
struct HistoryChart: View {
    var samples: [History.Sample]
    var range: TimeInterval
    var shortTitle: String
    var longTitle: String

    @Environment(\.colorScheme) private var scheme

    private struct Point: Identifiable {
        var id: String { "\(series)-\(t.timeIntervalSince1970)" }
        var series: String
        var t: Date
        var v: Double
    }

    var body: some View {
        let p = Palette.resolve(scheme)
        let cutoff = Date.now.addingTimeInterval(-range)
        let recent = Self.thinned(samples.filter { $0.t >= cutoff }, range: range)
        let points = recent.flatMap { s -> [Point] in
            [s.session.map { Point(series: shortTitle, t: s.t, v: $0) }, s.long.map { Point(series: longTitle, t: s.t, v: $0) }].compactMap { $0 }
        }
        Chart {
            RuleMark(y: .value("Nearly out", Alerts.criticalPercent))
                .foregroundStyle(p.markCritical.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(points) { point in
                LineMark(x: .value("Time", point.t), y: .value("Used", point.v))
                    .foregroundStyle(by: .value("Window", point.series))
                    .lineStyle(StrokeStyle(lineWidth: point.series == shortTitle ? 1.75 : 1.25, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale([shortTitle: p.ink, longTitle: p.muted])
        .chartYScale(domain: 0...100)
        .chartXScale(domain: cutoff...Date.now)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(p.divider)
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 10)).foregroundStyle(p.muted) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: range > 2 * 86400 ? .day : .hour, count: range > 14 * 86400 ? (range > 45 * 86400 ? 14 : 5) : range > 2 * 86400 ? 1 : 6)) { value in
                AxisGridLine().foregroundStyle(p.divider)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Group {
                            if range > 14 * 86400 { Text(date, format: .dateTime.month(.abbreviated).day()) }
                            else if range > 2 * 86400 { Text(date, format: .dateTime.weekday(.abbreviated)) }
                            else { Text(date, format: .dateTime.hour()) }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(p.muted)
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ForEach([shortTitle, longTitle], id: \.self) { title in
                    HStack(spacing: 4) {
                        Capsule().fill(title == shortTitle ? p.ink : p.muted).frame(width: 10, height: 2)
                        Text(title).font(.system(size: 10.5)).foregroundStyle(p.muted)
                    }
                }
            }
        }
        .frame(height: 96)
    }

    /// Long ranges are drawn from one sample per bucket (the fullest, so peaks survive) — a month at every poll is
    /// tens of thousands of marks, and the line looks the same at a few hundred.
    static func thinned(_ samples: [History.Sample], range: TimeInterval) -> [History.Sample] {
        guard range > 14 * 86400 else { return samples }
        let bucket: TimeInterval = range > 45 * 86400 ? 6 * 3600 : 2 * 3600
        var out: [History.Sample] = []
        var current: Int?
        for sample in samples {
            let key = Int(sample.t.timeIntervalSince1970 / bucket)
            if key == current, let last = out.last {
                let fuller = max(sample.session ?? 0, sample.long ?? 0) >= max(last.session ?? 0, last.long ?? 0)
                if fuller { out[out.count - 1] = sample }
            } else {
                out.append(sample)
                current = key
            }
        }
        return out
    }
}
