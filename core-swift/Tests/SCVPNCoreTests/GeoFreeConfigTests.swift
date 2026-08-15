import XCTest
@testable import SCVPNCore

/// Конфиг без гео-баз: на iOS расширение живёт в лимите памяти, и `geoip.dat`
/// туда не помещается. Проверки общие для платформ — сборка конфига одна.
final class GeoFreeConfigTests: XCTestCase {

    private let server = Server(proto: "vless", name: "тест", address: "a.b", port: 443,
                                uuid: "u", network: "tcp", security: "tls")

    private func json(_ cfg: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
    }

    private func rules(_ cfg: [String: Any]) throws -> [[String: Any]] {
        let routing = try XCTUnwrap(cfg["routing"] as? [String: Any])
        return try XCTUnwrap(routing["rules"] as? [[String: Any]])
    }

    func test_no_geo_references_anywhere_in_the_config() throws {
        let text = try json(try buildXrayConfig(server: server, geoAssets: false))
        XCTAssertFalse(text.contains("geoip:"), "осталась ссылка на geoip.dat")
        XCTAssertFalse(text.contains("geosite:"), "осталась ссылка на geosite.dat")
    }

    func test_private_networks_still_go_direct() throws {
        let cfg = try buildXrayConfig(server: server, geoAssets: false)
        let direct = try rules(cfg).first { $0["outboundTag"] as? String == "direct" }
        let ips = try XCTUnwrap(direct?["ip"] as? [String])
        XCTAssertTrue(ips.contains("192.168.0.0/16"))
        XCTAssertTrue(ips.contains("127.0.0.0/8"))
        XCTAssertTrue(ips.contains("fc00::/7"))
    }

    func test_rule_order_is_unchanged() throws {
        // Инвариант: приватные адреса раньше «всё остальное в прокси». Xray
        // берёт первое совпавшее правило, поэтому перестановка меняет поведение.
        let list = try rules(try buildXrayConfig(server: server, geoAssets: false))
        XCTAssertEqual(list.first?["outboundTag"] as? String, "direct")
        XCTAssertEqual(list.last?["outboundTag"] as? String, "proxy")
    }

    func test_bypass_ru_without_geo_is_refused_by_name() {
        XCTAssertThrowsError(try buildXrayConfig(server: server, routeMode: .bypassRU,
                                                 geoAssets: false)) { error in
            XCTAssertEqual(error as? XrayConfigError, .geoRequired("обход РФ"))
        }
    }

    func test_block_ads_without_geo_is_refused_by_name() {
        XCTAssertThrowsError(try buildXrayConfig(server: server, blockAds: true,
                                                 geoAssets: false)) { error in
            XCTAssertEqual(error as? XrayConfigError, .geoRequired("блокировка рекламы"))
        }
    }

    func test_desktop_config_is_untouched() throws {
        // Умолчание — geoAssets: true, то есть macOS-конфиг прежний.
        XCTAssertTrue(try json(try buildXrayConfig(server: server)).contains("geoip:private"))
    }

    func test_probe_config_has_one_outbound_and_no_inbounds() throws {
        let text = try buildProbeConfig(server: server)
        let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((cfg["outbounds"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(cfg["inbounds"])
        XCTAssertFalse(text.contains("geoip:"))
    }
}
