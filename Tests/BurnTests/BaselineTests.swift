import XCTest
@testable import Burn

final class BaselineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Three workdays of steady use — `rate` points per hour for eight hours a day, sampled every five minutes —
    /// ending `endingHoursAgo` before now, with a reset to 0 each morning.
    func workdays(rate: Double, days: Int = 3, endingHoursAgo: Double = 2) -> [(t: Date, used: Double)] {
        var points: [(t: Date, used: Double)] = []
        for day in stride(from: days, through: 1, by: -1) {
            let start = now.addingTimeInterval(-Double(day) * 86400 - endingHoursAgo * 3600)
            var used = 0.0
            for minute in stride(from: 0, through: 8 * 60, by: 5) {
                points.append((t: start.addingTimeInterval(Double(minute) * 60), used: used))
                used += rate / 12
            }
        }
        return points
    }

    func testSteadyUseGivesItsRate() {
        let typical = Baseline.typicalRate(points: workdays(rate: 8), kind: .session, now: now)
        XCTAssertEqual(typical ?? 0, 8, accuracy: 0.01)
    }

    func testOneWildHourDoesNotMoveTheNorm() {
        var points = workdays(rate: 8)
        // One frantic hour two days ago, on top of the usual.
        let spike = now.addingTimeInterval(-2 * 86400 - 12 * 3600)
        for minute in stride(from: 0, through: 60, by: 5) {
            points.append((t: spike.addingTimeInterval(Double(minute) * 60), used: 50 + Double(minute) * 40 / 60))
        }
        points.sort { $0.t < $1.t }
        let typical = Baseline.typicalRate(points: points, kind: .session, now: now)
        XCTAssertEqual(typical ?? 0, 8, accuracy: 0.5)
    }

    func testTheLookbackIsLeftOut() {
        // The last hour is a 40 %/h surge; the week before it was 8 %/h. The surge must not set its own bar.
        var points = workdays(rate: 8, endingHoursAgo: 3)
        let recent = now.addingTimeInterval(-3600)
        for minute in stride(from: 0, through: 60, by: 5) {
            points.append((t: recent.addingTimeInterval(Double(minute) * 60), used: 30 + Double(minute) * 40 / 60))
        }
        let typical = Baseline.typicalRate(points: points, kind: .session, now: now)
        XCTAssertEqual(typical ?? 0, 8, accuracy: 0.01)
    }

    func testGapsAndResetsAreSkipped() {
        var points = workdays(rate: 8)
        // A reset (90 → 5) and a sleep gap (three hours) must not count as consumption.
        let t = now.addingTimeInterval(-36 * 3600)
        points.append(contentsOf: [(t: t, used: 90), (t: t.addingTimeInterval(300), used: 5), (t: t.addingTimeInterval(3 * 3600 + 300), used: 60)])
        points.sort { $0.t < $1.t }
        let typical = Baseline.typicalRate(points: points, kind: .session, now: now)
        XCTAssertEqual(typical ?? 0, 8, accuracy: 0.01)
    }

    func testTypicalIsABusyHourNotALightOne() {
        // Sixteen light hours at 2 %/h and eight focused ones at 12 %/h: "usual" is the focused kind, so a 16 %/h
        // hour is 1.3× usual, not 8×.
        var points: [(t: Date, used: Double)] = []
        for hour in 0..<24 {
            let start = now.addingTimeInterval(-Double(hour + 2) * 3600 - (hour < 12 ? 0 : 86400))
            let rate = hour % 3 == 0 ? 12.0 : 2.0
            var used = 10.0
            for minute in stride(from: 0, to: 60, by: 5) {
                points.append((t: start.addingTimeInterval(Double(minute) * 60), used: used))
                used += rate / 12
            }
        }
        points.sort { $0.t < $1.t }
        let typical = Baseline.typicalRate(points: points, kind: .session, now: now) ?? 0
        XCTAssertEqual(typical, 12, accuracy: 1)
    }

    func testTooLittleHistoryIsNil() {
        XCTAssertNil(Baseline.typicalRate(points: workdays(rate: 8, days: 1), kind: .session, now: now), "one day is not a week")
        XCTAssertNil(Baseline.typicalRate(points: [], kind: .session, now: now))
    }

    func testTypicalDayLeavesTodayOut() {
        let costs = ["2026-09-01": 60.0, "2026-09-02": 80, "2026-09-03": 70, "2026-09-04": 0.5, "2026-09-05": 90, "2026-09-06": 75, "2026-09-07": 900]
        XCTAssertEqual(Baseline.typicalDaily(costs: costs, today: "2026-09-07"), 80, "the busy-day norm of 60, 70, 75, 80, 90 — today's $900 and the $0.50 day don't count")
        XCTAssertNil(Baseline.typicalDaily(costs: ["2026-09-01": 60, "2026-09-02": 80, "2026-09-03": 70], today: "2026-09-04"), "fewer than five active days")
    }

    func testMultipleAndText() {
        var pace = Pace(rate: 28, runOut: nil, expectedNow: nil, verdict: .onPace, shortfall: nil)
        XCTAssertNil(pace.multiple)
        pace.typical = 9
        XCTAssertEqual(pace.multiple ?? 0, 28.0 / 9, accuracy: 0.001)
        XCTAssertEqual(Baseline.multipleText(3.04), "3×")
        XCTAssertEqual(Baseline.multipleText(2.56), "2.6×")
        XCTAssertEqual(Baseline.multipleText(12.4), "12×")
        XCTAssertTrue(Alerts.isSurging(pace, kind: .session, threshold: 3))
        XCTAssertFalse(Alerts.isSurging(pace, kind: .session, threshold: 5))
        XCTAssertFalse(Alerts.isSurging(Pace(rate: 4, runOut: nil, expectedNow: nil, verdict: .onPace, shortfall: nil, typical: 1), kind: .session, threshold: 3), "below the floor a multiple means nothing")
    }

    func testOlderPaceFilesStillDecode() throws {
        let json = #"{"rate":12,"verdict":"onPace"}"#.data(using: .utf8)!
        let pace = try JSONDecoder().decode(Pace.self, from: json)
        XCTAssertNil(pace.typical)
        XCTAssertNil(pace.multiple)
    }

    func testModelNames() {
        XCTAssertEqual(Alerts.modelName("claude-opus-5"), "Opus 5")
        XCTAssertEqual(Alerts.modelName("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(Alerts.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(Alerts.tokens(27_400_000), "27M")
        XCTAssertEqual(Alerts.tokens(840_000), "840K")
    }
}
