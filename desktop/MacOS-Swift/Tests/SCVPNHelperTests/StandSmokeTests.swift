import XCTest
@testable import SCVPNHelperKit

/// Дымовая проверка самого стенда. Стенд держит все остальные проверки демона;
/// молча сломанный стенд позеленил бы их все разом, ничего не проверив.
final class StandSmokeTests: XCTestCase {

    func test_stand_starts_and_stops_fake_singbox() throws {
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        stand.supervisor.stop()
        XCTAssertTrue(stand.waitGone(timeout: 10))
    }

    func test_stubborn_singbox_really_ignores_sigterm() throws {
        // Если «упрямый» скрипт на деле уходит по SIGTERM, все проверки,
        // построенные на нём, зеленеют, не проверив ничего.
        let stand = try Stand(script: .stubborn).serveHere()
        defer { stand.tearDown() }
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        let pid = Int32(stand.singboxPIDs().first ?? "0") ?? 0
        XCTAssertGreaterThan(pid, 0)
        kill(pid, SIGTERM)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(stand.singboxPIDs().isEmpty, "«упрямый» sing-box ушёл по SIGTERM")
    }
}
