#if os(macOS)
import XCTest
@testable import SCVPNCore

/// Резолв адреса сервера для запасного пояса `route_exclude_address`.
///
/// Живой DNS тут не проверяем — он есть в тестах демона. Здесь важны литералы:
/// именно на IPv6-литерале прежний IPv4-only резолв отдавал пустой список, и
/// трафик ядра к серверу уходил обратно в туннель.
final class ResolveIPsTests: XCTestCase {

    func test_ipv6_literal_resolves_to_itself() {
        XCTAssertEqual(resolveIPs("2001:db8::1"), ["2001:db8::1"])
        XCTAssertEqual(resolveIPs("::1"), ["::1"])
        // Канон тот же, что у адресов от клиента: сжатые нули, нижний регистр.
        XCTAssertEqual(resolveIPs("2001:0DB8:0000:0000:0000:0000:0000:0001"),
                       ["2001:db8::1"])
    }

    func test_ipv4_literal_still_resolves_to_itself() {
        XCTAssertEqual(resolveIPs("1.2.3.4"), ["1.2.3.4"])
    }

    // Что не литерал — уходит в getaddrinfo, и проверять это здесь нечем:
    // сеть в тестах не гарантирована, а «1.2.3» libc сам разворачивает в
    // 1.2.0.3. Живой резолв проверяют тесты демона.
}
#endif
