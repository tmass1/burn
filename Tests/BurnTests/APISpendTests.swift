import XCTest
@testable import Burn

final class APISpendTests: XCTestCase {
    func testPricesByModelFamily() {
        XCTAssertEqual(APISpend.Price.forModel("claude-opus-5")?.input, 5)
        XCTAssertEqual(APISpend.Price.forModel("claude-sonnet-5")?.output, 10)
        XCTAssertEqual(APISpend.Price.forModel("claude-sonnet-4-6")?.input, 3)
        XCTAssertEqual(APISpend.Price.forModel("claude-fable-5-1")?.cacheRead, 0.25)
        XCTAssertEqual(APISpend.Price.forModel("claude-haiku-4-5-20251001")?.input, 1)
        XCTAssertNil(APISpend.Price.forModel("gpt-5.6-luna"))
    }

    func testCostArithmetic() {
        let price = APISpend.Price(input: 5, output: 25, cacheRead: 0.5)
        var t = APISpend.Totals()
        t.input = 1_000_000; t.output = 100_000; t.cacheRead = 2_000_000; t.cacheWrite5m = 100_000; t.cacheWrite1h = 100_000
        // 5 + 2.5 + 1 + 0.625 + 1.0
        XCTAssertEqual(price.cost(t), 10.125, accuracy: 0.0001)
    }

    func testScanCountsEachMessageOnceAndResumes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burn-spend-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let log = projects.appendingPathComponent("s.jsonl")
        let stamp = ISO8601DateFormatter().string(from: .now)
        func line(id: String, req: String, out: Int) -> String {
            """
            {"type":"assistant","timestamp":"\(stamp)","requestId":"\(req)","message":{"id":"\(id)","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":\(out),"cache_read_input_tokens":1000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":300}}}}
            """
        }
        // Two streamed chunks of one message, then a different message, then a user line and a half-written line.
        var text = [line(id: "m1", req: "r1", out: 40), line(id: "m1", req: "r1", out: 40), line(id: "m2", req: "r2", out: 60),
                    #"{"type":"user","message":{"role":"user"}}"#].joined(separator: "\n") + "\n"
        text += #"{"type":"assistant","timestamp":""# // no newline: still being written
        try text.write(to: log, atomically: true, encoding: .utf8)

        var state = APISpend.Scanner.scan(dirs: [root.path], state: APISpend.State())
        let day = APISpend.dayKey(.now)
        let totals = try XCTUnwrap(state.days[root.path]?[day]?["claude-opus-5"])
        XCTAssertEqual(totals.messages, 2)
        XCTAssertEqual(totals.output, 100)
        XCTAssertEqual(totals.cacheWrite1h, 400)
        XCTAssertEqual(totals.cacheWrite5m, 600)

        // The half line completes and a third message arrives; only the new part is read.
        let yesterday = Date.now.addingTimeInterval(-86400)
        let more = "\(ISO8601DateFormatter().string(from: yesterday))\",\"requestId\":\"r3\",\"message\":{\"id\":\"m3\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n"
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(more.utf8))
        try handle.close()
        state = APISpend.Scanner.scan(dirs: [root.path], state: state)
        XCTAssertEqual(state.days[root.path]?[day]?["claude-opus-5"]?.messages, 2)
        XCTAssertEqual(state.days[root.path]?[APISpend.dayKey(yesterday)]?["claude-sonnet-5"]?.messages, 1)
        try? FileManager.default.removeItem(at: root)
    }
}
