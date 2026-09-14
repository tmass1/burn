import XCTest
@testable import Burn

final class LaunchersTests: XCTestCase {
    @MainActor
    func testSlugs() {
        XCTAssertEqual(Launchers.slug("Studio Team"), "studio-team")
        XCTAssertEqual(Launchers.slug("Atlas"), "atlas")
        XCTAssertEqual(Launchers.slug("  Tommy's  Personal! "), "tommy-s-personal")
        XCTAssertEqual(Launchers.slug("Éclair Co"), "eclair-co")
        XCTAssertEqual(Launchers.slug("---"), "account")
    }
}
