import Foundation

/// A retry schedule per account, so one profile a vendor won't serve right now doesn't slow the others down.
/// A failure books the next attempt 2, 4, 8 … minutes out (30 at most); a success clears the slate. Providers
/// consult it before each poll and hand back the last problem, with the retry time, for accounts still waiting.
actor RetrySchedule {
    static let shared = RetrySchedule()

    struct Hold: Sendable {
        var until: Date
        var problem: AccountProblem
    }

    private var failures: [String: Int] = [:]
    private var holds: [String: Hold] = [:]

    /// The hold on an account, if its next attempt is still in the future.
    func hold(for key: String, now: Date = .now) -> Hold? {
        guard let hold = holds[key], hold.until > now else { return nil }
        return hold
    }

    /// Records a failure and returns when the account may try again.
    @discardableResult
    func failed(_ key: String, problem: AccountProblem, now: Date = .now) -> Date {
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        let until = now.addingTimeInterval(Self.delay(afterFailures: count))
        holds[key] = Hold(until: until, problem: problem)
        return until
    }

    func succeeded(_ key: String) {
        failures[key] = nil
        holds[key] = nil
    }

    /// A refresh the user asked for tries everything again right away.
    func reset() {
        failures = [:]
        holds = [:]
    }

    nonisolated static func delay(afterFailures count: Int) -> TimeInterval {
        min(1800, 120 * pow(2, Double(max(1, count) - 1)))
    }
}
