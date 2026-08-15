import XCTest
@testable import SCVPNCore

final class ValidationTests: XCTestCase {

    func test_rejects_non_object_params() {
        // Кадр из сокета — это разобранный JSON от клиента, а JSON-документ
        // законно может оказаться списком, строкой или числом, не только
        // объектом. Поэтому validate принимает Any, а не [String: Any]:
        // сигнатура с готовым словарём эту ветку просто не имела бы.
        XCTAssertThrowsError(try validate([1, 2, 3]))
        XCTAssertThrowsError(try validate("не объект"))
        XCTAssertThrowsError(try validate(42))
    }

    func test_rejects_unknown_split_mode() {
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_mode": "нет"]))
    }

    func test_rejects_missing_port() {
        XCTAssertThrowsError(try validate([:] as [String: Any]))
    }

    func test_rejects_boolean_as_port() {
        // В Python bool — подкласс int, и True прошёл бы как порт 1.
        // В Swift JSONSerialization отдаёт NSNumber, у которого тот же
        // подвох: `as? Int` на булевом NSNumber даёт 1. Проверка обязана
        // его ловить.
        XCTAssertThrowsError(try validate(["socks_port": true]))
        let fromJSON = try! JSONSerialization.jsonObject(with: Data(#"{"socks_port": true}"#.utf8))
        XCTAssertThrowsError(try validate(fromJSON))
    }

    func test_rejects_port_out_of_range() {
        XCTAssertThrowsError(try validate(["socks_port": 0]))
        XCTAssertThrowsError(try validate(["socks_port": 65536]))
        XCTAssertThrowsError(try validate(["socks_port": -1]))
    }

    func test_accepts_edges_of_the_port_range() throws {
        XCTAssertEqual(try validate(["socks_port": 1]).socksPort, 1)
        XCTAssertEqual(try validate(["socks_port": 65535]).socksPort, 65535)
    }

    func test_rejects_app_name_that_is_a_path() {
        XCTAssertThrowsError(try validate(["socks_port": 10808,
                                           "split_apps": ["/usr/bin/curl"]]))
        XCTAssertThrowsError(try validate(["socks_port": 10808,
                                           "split_apps": ["C:\\Windows\\curl"]]))
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_apps": ["."]]))
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_apps": [".."]]))
    }

    func test_rejects_empty_and_oversized_app_names() {
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_apps": ["   "]]))
        let long = String(repeating: "я", count: 65)
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_apps": [long]]))
    }

    func test_app_names_are_trimmed() throws {
        let p = try validate(["socks_port": 10808, "split_apps": ["  Safari  "]])
        XCTAssertEqual(p.splitApps, ["Safari"])
    }

    func test_rejects_non_string_app_name() {
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_apps": [17]]))
    }

    func test_rejects_split_apps_that_is_not_a_list() {
        XCTAssertThrowsError(try validate(["socks_port": 10808, "split_apps": "Safari"]))
    }

    func test_rejects_unknown_stack() {
        XCTAssertThrowsError(try validate(["socks_port": 10808, "stack": "нет такого"]))
    }

    func test_stack_defaults_to_gvisor() throws {
        XCTAssertEqual(try validate(["socks_port": 10808]).stack, .gvisor)
    }

    func test_drops_garbage_from_exclude_ips_silently() throws {
        let p = try validate(["socks_port": 10808,
                              "exclude_ips": ["1.2.3.4", 5, "не адрес", "::1"]])
        XCTAssertEqual(p.excludeIPs, ["1.2.3.4", "::1"])
    }

    func test_does_not_take_numbers_for_addresses() throws {
        // ipaddress.ip_address() в Python принимает int и bool: «истинность»
        // числа молча превращается в правдоподобный IPv4. Запасной пояс,
        // собранный из выдуманных адресов, поясом не является.
        let p = try validate(["socks_port": 10808, "exclude_ips": [true, 16843009]])
        XCTAssertEqual(p.excludeIPs, [])
    }

    func test_normalizes_addresses_the_way_python_did() throws {
        let p = try validate(["socks_port": 10808,
                              "exclude_ips": ["2001:0DB8:0000:0000:0000:0000:0000:0001"]])
        XCTAssertEqual(p.excludeIPs, ["2001:db8::1"])
    }

    func test_rejects_exclude_ips_that_is_not_a_list() {
        XCTAssertThrowsError(try validate(["socks_port": 10808, "exclude_ips": "1.2.3.4"]))
    }

    func test_unknown_log_level_falls_back_to_warn() throws {
        let p = try validate(["socks_port": 10808, "log_level": "вопли"])
        XCTAssertEqual(p.logLevel, "warn")
        XCTAssertEqual(try validate(["socks_port": 10808, "log_level": 5]).logLevel, "warn")
        XCTAssertEqual(try validate(["socks_port": 10808]).logLevel, "warn")
    }

    func test_known_log_level_survives() throws {
        XCTAssertEqual(try validate(["socks_port": 10808, "log_level": "debug"]).logLevel, "debug")
    }
}
