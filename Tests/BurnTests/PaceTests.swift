import XCTest
@testable import Burn

final class PaceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A five-hour session window, `used` % now, resetting in `resetIn` seconds.
    func session(used: Double, resetIn: TimeInterval) -> UsageWindow {
        UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: used,
                    resetsAt: now.addingTimeInterval(resetIn), windowSeconds: 5 * 3600, detail: nil)
    }

    /// Readings every three minutes over the last `minutes`, rising linearly from `from` to `to`.
    func ramp(from: Double, to: Double, minutes: Int, endingAt end: Date? = nil) -> [(t: Date, used: Double)] {
        let end = end ?? now
        return stride(from: 0, through: minutes, by: 3).map { m in
            let f = Double(m) / Double(minutes)
            return (t: end.addingTimeInterval(-Double(minutes - m) * 60), used: from + (to - from) * f)
        }
    }

    func testSteadyRateRunsOutBeforeReset() {
        // 10 → 40 over an hour is 30 points an hour; 60 points left is two hours; the reset is three hours away.
        let pace = Pace.compute(points: ramp(from: 10, to: 40, minutes: 60), window: session(used: 40, resetIn: 3 * 3600), now: now)
        XCTAssertEqual(pace.rate, 30, accuracy: 0.5)
        XCTAssertEqual(pace.verdict, .fast)
        XCTAssertEqual(pace.runOut!.timeIntervalSince(now), 2 * 3600, accuracy: 120)
        XCTAssertEqual(pace.shortfall!, 3600, accuracy: 120)
        // Two hours into a five-hour window, even use would sit at 40 %.
        XCTAssertEqual(pace.expectedNow!, 40, accuracy: 0.5)
    }

    func testOnPaceWhenTheResetComesFirst() {
        // 4 points an hour with 60 left is fifteen hours; the reset is in two.
        let pace = Pace.compute(points: ramp(from: 36, to: 40, minutes: 60), window: session(used: 40, resetIn: 2 * 3600), now: now)
        XCTAssertEqual(pace.verdict, .onPace)
        XCTAssertEqual(pace.rate, 4, accuracy: 0.2)
    }

    func testResetMidRunOnlyCountsWhatCameAfter() {
        // Up to 80 %, a reset to 5 %, then twenty minutes at 30 points an hour.
        let before = ramp(from: 50, to: 80, minutes: 30, endingAt: now.addingTimeInterval(-21 * 60))
        let after = ramp(from: 5, to: 15, minutes: 20)
        let pace = Pace.compute(points: before + after, window: session(used: 15, resetIn: 4 * 3600), now: now)
        XCTAssertEqual(pace.rate, 30, accuracy: 1)
        XCTAssertEqual(pace.verdict, .fast)
    }

    func testSleepGapStartsTheRunAgain() {
        // Plenty of samples, then the lid closed for forty minutes, then two readings — not enough to say anything.
        let earlier = ramp(from: 10, to: 30, minutes: 60, endingAt: now.addingTimeInterval(-43 * 60))
        let recent = [(t: now.addingTimeInterval(-3 * 60), used: 31.0), (t: now, used: 32.0)]
        let pace = Pace.compute(points: earlier + recent, window: session(used: 32, resetIn: 3 * 3600), now: now)
        XCTAssertEqual(pace.verdict, .early)
        XCTAssertNil(pace.runOut)
    }

    func testTooFewSamplesIsEarly() {
        let pace = Pace.compute(points: ramp(from: 10, to: 20, minutes: 6), window: session(used: 20, resetIn: 3600), now: now)
        XCTAssertEqual(pace.verdict, .early)
    }

    func testFlatUsageIsStalled() {
        let pace = Pace.compute(points: ramp(from: 40, to: 40, minutes: 60), window: session(used: 40, resetIn: 3600), now: now)
        XCTAssertEqual(pace.verdict, .stalled)
        XCTAssertEqual(pace.rate, 0)
    }

    func testMarginScalesWithTheWindow() {
        XCTAssertEqual(Pace.margin(windowSeconds: 5 * 3600), 30 * 60)      // a tenth of five hours is under the floor
        XCTAssertEqual(Pace.margin(windowSeconds: 7 * 86400), 0.7 * 86400, accuracy: 0.001) // a tenth of a week
        XCTAssertEqual(Pace.margin(windowSeconds: nil), 30 * 60)
    }

    func testForecastPastTheLimitWhenItRunsOutFirst() {
        // 30 points an hour from 40 % with three hours to go lands at 130: "out".
        let window = session(used: 40, resetIn: 3 * 3600)
        let pace = Pace.compute(points: ramp(from: 10, to: 40, minutes: 60), window: window, now: now)
        XCTAssertEqual(pace.forecast(for: window, now: now)!, 130, accuracy: 2)
    }

    func testForecastLandsShortOfTheLimitOnPace() {
        // 4 points an hour from 40 % with two hours to go lands at 48.
        let window = session(used: 40, resetIn: 2 * 3600)
        let pace = Pace.compute(points: ramp(from: 36, to: 40, minutes: 60), window: window, now: now)
        XCTAssertEqual(pace.forecast(for: window, now: now)!, 48, accuracy: 0.5)
    }

    func testForecastInsideTheMarginStopsAtTheLimit() {
        // 30 points an hour from 70 % with 1h10m to go reaches 100 ten minutes early — inside the half-hour margin,
        // so it is on pace and the forecast stops at 100 rather than saying "out".
        let window = session(used: 70, resetIn: 70 * 60)
        let pace = Pace.compute(points: ramp(from: 40, to: 70, minutes: 60), window: window, now: now)
        XCTAssertEqual(pace.verdict, .onPace)
        XCTAssertEqual(pace.forecast(for: window, now: now), 100)
    }

    func testForecastOfIdleIsWhereItIsAndEarlyIsUnknown() {
        let window = session(used: 40, resetIn: 3600)
        let stalled = Pace.compute(points: ramp(from: 40, to: 40, minutes: 60), window: window, now: now)
        XCTAssertEqual(stalled.forecast(for: window, now: now), 40)
        let early = Pace.compute(points: ramp(from: 38, to: 40, minutes: 6), window: window, now: now)
        XCTAssertNil(early.forecast(for: window, now: now))
    }

    func testNoResetMeansNoMarkerAndNeverFast() {
        var window = session(used: 70, resetIn: 3600)
        window.resetsAt = nil
        window.windowSeconds = nil
        let pace = Pace.compute(points: ramp(from: 40, to: 70, minutes: 60), window: window, now: now)
        XCTAssertNil(pace.expectedNow)
        XCTAssertEqual(pace.verdict, .onPace)
        XCTAssertNotNil(pace.runOut)
    }
}
