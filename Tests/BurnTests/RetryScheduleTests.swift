import XCTest
@testable import Burn

final class RetryScheduleTests: XCTestCase {
    private let problem = AccountProblem(kind: .throttled, title: "Rate limited", hint: "Backing off.", command: nil)

    func testDelayDoublesAndCaps() {
        XCTAssertEqual(RetrySchedule.delay(afterFailures: 1), 120)
        XCTAssertEqual(RetrySchedule.delay(afterFailures: 2), 240)
        XCTAssertEqual(RetrySchedule.delay(afterFailures: 4), 960)
        XCTAssertEqual(RetrySchedule.delay(afterFailures: 5), 1800)
        XCTAssertEqual(RetrySchedule.delay(afterFailures: 9), 1800)
    }

    func testHoldCoversOnlyTheFailedAccount() async {
        let schedule = RetrySchedule()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let until = await schedule.failed("personal", problem: problem, now: t0)
        XCTAssertEqual(until, t0.addingTimeInterval(120))
        let held = await schedule.hold(for: "personal", now: t0.addingTimeInterval(60))
        XCTAssertEqual(held?.problem.title, "Rate limited")
        let other = await schedule.hold(for: "studio", now: t0.addingTimeInterval(60))
        XCTAssertNil(other)
        let later = await schedule.hold(for: "personal", now: t0.addingTimeInterval(121))
        XCTAssertNil(later, "the hold lifts once its time has passed")
    }

    func testSuccessAndResetClearTheSlate() async {
        let schedule = RetrySchedule()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        await schedule.failed("personal", problem: problem, now: t0)
        await schedule.failed("personal", problem: problem, now: t0)
        await schedule.succeeded("personal")
        let afterSuccess = await schedule.failed("personal", problem: problem, now: t0)
        XCTAssertEqual(afterSuccess, t0.addingTimeInterval(120), "a success resets the doubling")
        await schedule.reset()
        let held = await schedule.hold(for: "personal", now: t0)
        XCTAssertNil(held)
    }
}
