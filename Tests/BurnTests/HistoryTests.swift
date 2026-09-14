import XCTest
@testable import Burn

final class HistoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testOldSamplesThinToOnePerHour() {
        // Ten days of samples every three minutes; the last seven days stay dense, the first three become hourly.
        var list: [History.Sample] = []
        var t = now.addingTimeInterval(-10 * 86400)
        while t <= now {
            list.append(History.Sample(t: t, session: 10, weekly: 20))
            t = t.addingTimeInterval(180)
        }
        let compact = History.compacted(list, now: now)
        let boundary = now.addingTimeInterval(-History.denseFor)
        let dense = compact.filter { $0.t >= boundary }.count
        let sparse = compact.filter { $0.t < boundary }.count
        XCTAssertEqual(dense, list.filter { $0.t >= boundary }.count)
        XCTAssertEqual(sparse, 3 * 24, accuracy: 2)
        // Order and the newest sample survive.
        XCTAssertEqual(compact.last?.t, list.last?.t)
        XCTAssertEqual(compact, compact.sorted { $0.t < $1.t })
    }

    func testChartThinningKeepsPeaks() {
        var list: [History.Sample] = []
        for minute in stride(from: 0, to: 24 * 60, by: 3) {
            list.append(History.Sample(t: now.addingTimeInterval(Double(minute) * 60), session: minute == 61 * 3 ? 95 : 10, weekly: nil))
        }
        let thin = HistoryChart.thinned(list, range: 30 * 86400)
        XCTAssertLessThan(thin.count, 20)
        XCTAssertEqual(thin.map { $0.session ?? 0 }.max(), 95)
    }
}
