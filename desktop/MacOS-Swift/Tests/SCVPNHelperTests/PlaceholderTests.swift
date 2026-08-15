import XCTest
@testable import SCVPNHelperKit

final class HelperKitPlaceholderTests: XCTestCase {
    func test_package_builds() {
        XCTAssertEqual(SCVPNHelperKit.buildMarker, "scvpn-helper-kit")
    }
}
