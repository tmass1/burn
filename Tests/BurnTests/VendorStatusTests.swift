import XCTest
@testable import Burn

final class VendorStatusTests: XCTestCase {
    let claude = ["claude.ai", "Claude API", "Claude Code"]

    func summary(components: [(String, String)], incidents: [(name: String, status: String, components: [String])] = [], indicator: String = "none") -> Data {
        let root: [String: Any] = [
            "status": ["indicator": indicator, "description": "x"],
            "components": components.map { ["name": $0.0, "status": $0.1] },
            "incidents": incidents.map { ["name": $0.name, "status": $0.status, "impact": "minor", "components": $0.components.map { ["name": $0] }] },
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    func testAllOperationalIsFine() {
        let data = summary(components: [("claude.ai", "operational"), ("Claude Code", "operational")])
        XCTAssertEqual(VendorStatus.parse(data, components: claude), .fine)
    }

    func testUnrelatedComponentNeverCounts() {
        // Today's real shape: a partial outage on Claude Cowork, page indicator "minor" — nothing to do with us.
        let data = summary(components: [("claude.ai", "operational"), ("Claude Cowork", "partial_outage")],
                           incidents: [("Degraded functionality for Claude Cowork on Windows", "identified", ["Claude Cowork"])], indicator: "minor")
        XCTAssertEqual(VendorStatus.parse(data, components: claude), .fine)
    }

    func testDegradedComponentIsNamedByItsIncident() {
        let data = summary(components: [("claude.ai", "degraded_performance"), ("Claude Code", "operational")],
                           incidents: [("Elevated errors on claude.ai", "monitoring", ["claude.ai"])], indicator: "minor")
        XCTAssertEqual(VendorStatus.parse(data, components: claude), .degraded("Elevated errors on claude.ai"))
    }

    func testMajorOutageOnOurComponentIsAnOutage() {
        let data = summary(components: [("Claude Code", "major_outage")], indicator: "major")
        XCTAssertEqual(VendorStatus.parse(data, components: claude), .outage("Major outage"))
    }

    func testResolvedIncidentsAreIgnored() {
        let data = summary(components: [("claude.ai", "operational")],
                           incidents: [("Old trouble", "resolved", ["claude.ai"])])
        XCTAssertEqual(VendorStatus.parse(data, components: claude), .fine)
    }

    func testOpenIncidentOnOurComponentCountsEvenIfComponentsReadOperational() {
        let data = summary(components: [("Claude API (api.anthropic.com)", "operational")],
                           incidents: [("Elevated API latency", "investigating", ["Claude API (api.anthropic.com)"])])
        XCTAssertEqual(VendorStatus.parse(data, components: claude), .degraded("Elevated API latency"))
    }

    func testPrefixMatchingIsCaseInsensitive() {
        let data = summary(components: [("CLAUDE CODE", "partial_outage")])
        XCTAssertEqual(VendorStatus.parse(data, components: claude), .outage("Partial outage"))
    }

    func testGarbageIsNil() {
        XCTAssertNil(VendorStatus.parse(Data("nope".utf8), components: claude))
    }
}
