import XCTest
@testable import SCVPNCore

final class XrayConfigTests: XCTestCase {

    private let server = Server(proto: "vless", address: "a.b", port: 443,
                                uuid: "u", security: "reality")

    private func rules(_ cfg: [String: Any]) -> [[String: Any]] {
        (cfg["routing"] as! [String: Any])["rules"] as! [[String: Any]]
    }

    private func tags(_ cfg: [String: Any]) -> [String] {
        rules(cfg).map { $0["outboundTag"] as! String }
    }

    func test_private_addresses_always_go_direct() throws {
        let cfg = try buildXrayConfig(server: server)
        // Без этих правил локальная сеть уходила бы в туннель, и принтер с
        // роутером переставали бы отвечать при включённом VPN.
        let direct = rules(cfg).filter { $0["outboundTag"] as? String == "direct" }
        XCTAssertTrue(direct.contains { ($0["ip"] as? [String]) == ["geoip:private"] })
        XCTAssertTrue(direct.contains { ($0["domain"] as? [String]) == ["geosite:private"] })
    }

    func test_block_ads_rule_comes_first() throws {
        // Xray берёт первое совпавшее правило: встань блокировка после
        // «всё остальное в proxy», она не сработала бы никогда.
        let cfg = try buildXrayConfig(server: server, blockAds: true)
        XCTAssertEqual(tags(cfg).first, "block")
        XCTAssertEqual(rules(cfg)[0]["domain"] as? [String], ["geosite:category-ads-all"])
    }

    func test_without_block_ads_there_is_no_block_rule() throws {
        XCTAssertFalse(try tags(buildXrayConfig(server: server)).contains("block"))
    }

    func test_catch_all_proxy_rule_is_last() throws {
        for mode in [RouteMode.global, .bypassRU] {
            for ads in [true, false] {
                let cfg = try buildXrayConfig(server: server, routeMode: mode, blockAds: ads)
                XCTAssertEqual(tags(cfg).last, "proxy", "\(mode) ads=\(ads)")
                XCTAssertEqual(rules(cfg).last?["network"] as? String, "tcp,udp")
            }
        }
    }

    func test_bypass_ru_adds_ru_rules_before_the_catch_all() throws {
        let cfg = try buildXrayConfig(server: server, routeMode: .bypassRU)
        let ru = rules(cfg).firstIndex { ($0["ip"] as? [String]) == ["geoip:ru"] }
        let catchAll = rules(cfg).firstIndex { $0["network"] != nil }
        XCTAssertNotNil(ru)
        XCTAssertLessThan(ru!, catchAll!)
    }

    func test_global_mode_has_no_ru_rules() throws {
        let cfg = try buildXrayConfig(server: server, routeMode: .global)
        XCTAssertFalse(rules(cfg).contains { ($0["ip"] as? [String]) == ["geoip:ru"] })
    }

    func test_bypass_ru_puts_yandex_dns_first() throws {
        // Российские домены надо резолвить российским DNS напрямую: уйди
        // запрос в туннель, обход перестал бы быть обходом.
        let cfg = try buildXrayConfig(server: server, routeMode: .bypassRU)
        let servers = (cfg["dns"] as! [String: Any])["servers"] as! [Any]
        let first = servers[0] as! [String: Any]
        XCTAssertEqual(first["address"] as? String, "77.88.8.8")
        XCTAssertEqual(first["domains"] as? [String], ["geosite:category-ru"])
    }

    func test_global_dns_has_no_russian_resolver() throws {
        let cfg = try buildXrayConfig(server: server, routeMode: .global)
        let servers = (cfg["dns"] as! [String: Any])["servers"] as! [Any]
        XCTAssertEqual(servers.first as? String, "https://1.1.1.1/dns-query")
    }

    func test_inbounds_listen_on_loopback_only() throws {
        // Слушай эти порты на 0.0.0.0 — и любой в той же сети получил бы
        // открытый прокси через чужой VPN.
        let cfg = try buildXrayConfig(server: server, socksPort: 1080, httpPort: 1081)
        let ins = cfg["inbounds"] as! [[String: Any]]
        XCTAssertEqual(ins.map { $0["listen"] as! String }, ["127.0.0.1", "127.0.0.1"])
        XCTAssertEqual(ins[0]["port"] as? Int, 1080)
        XCTAssertEqual(ins[1]["port"] as? Int, 1081)
        XCTAssertEqual(ins[0]["protocol"] as? String, "socks")
        XCTAssertEqual(ins[1]["protocol"] as? String, "http")
    }

    func test_outbounds_order_puts_proxy_first() throws {
        // Умолчание Xray — первый outbound: встань direct первым, весь
        // непопавший под правила трафик пошёл бы мимо VPN.
        let cfg = try buildXrayConfig(server: server)
        let outs = cfg["outbounds"] as! [[String: Any]]
        XCTAssertEqual(outs.map { $0["tag"] as! String }, ["proxy", "direct", "block"])
    }

    func test_log_path_appears_only_when_asked() throws {
        var cfg = try buildXrayConfig(server: server)
        XCTAssertNil((cfg["log"] as! [String: Any])["access"])
        cfg = try buildXrayConfig(server: server, logPath: "/tmp/x.log")
        XCTAssertEqual((cfg["log"] as! [String: Any])["error"] as? String, "/tmp/x.log")
    }

    func test_config_survives_json_serialization() throws {
        for mode in [RouteMode.global, .bypassRU] {
            let cfg = try buildXrayConfig(server: server, routeMode: mode, blockAds: true)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(cfg))
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: cfg))
        }
    }

    func test_unknown_protocol_stops_the_whole_config() {
        XCTAssertThrowsError(try buildXrayConfig(server: Server(proto: "нет такого")))
    }
}
