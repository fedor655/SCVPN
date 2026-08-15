import XCTest
@testable import SCVPNCore

final class PlaceholderTests: XCTestCase {
    func test_package_builds() {
        XCTAssertEqual(SCVPNCore.buildMarker, "scvpn-core")
    }
}
