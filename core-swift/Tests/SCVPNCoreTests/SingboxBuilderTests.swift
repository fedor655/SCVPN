import XCTest
@testable import SCVPNCore

final class SingboxBuilderTests: XCTestCase {

    private func route(_ cfg: [String: Any]) -> [String: Any] {
        cfg["route"] as! [String: Any]
    }

    private func rules(_ cfg: [String: Any]) -> [[String: Any]] {
        route(cfg)["rules"] as! [[String: Any]]
    }

    func test_xray_always_goes_direct_and_first() throws {
        let p = try validate(["socks_port": 10808])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        // Первым правилом выводим из туннеля сам Xray: без этого соединение
        // ядра к серверу снова попадает в TUN, оттуда обратно в ядро — и так
        // по кругу.
        XCTAssertEqual(rules(cfg)[0]["process_path"] as? [String], ["/tmp/bin/xray"])
        XCTAssertEqual(rules(cfg)[0]["outbound"] as? String, "direct")
    }

    func test_xray_rule_stays_first_even_with_split_rules() throws {
        let p = try validate(["socks_port": 10808, "split_mode": "exclude",
                              "split_apps": ["Safari"]])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertEqual(rules(cfg).count, 2)
        XCTAssertNotNil(rules(cfg)[0]["process_path"])
        XCTAssertEqual(rules(cfg)[1]["process_name"] as? [String], ["Safari"])
    }

    func test_include_mode_sends_everything_else_direct() throws {
        let p = try validate(["socks_port": 10808, "split_mode": "include",
                              "split_apps": ["Safari"]])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertEqual(route(cfg)["final"] as? String, "direct")
        XCTAssertEqual(rules(cfg)[1]["outbound"] as? String, "to-xray")
    }

    func test_exclude_mode_keeps_final_in_tunnel() throws {
        let p = try validate(["socks_port": 10808, "split_mode": "exclude",
                              "split_apps": ["Safari"]])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertEqual(route(cfg)["final"] as? String, "to-xray")
        XCTAssertEqual(rules(cfg)[1]["outbound"] as? String, "direct")
    }

    func test_include_mode_without_apps_keeps_final_in_tunnel() throws {
        // Режим include с пустым списком не должен выкидывать весь трафик
        // мимо VPN: пользователь просил туннель, а не его отсутствие.
        let p = try validate(["socks_port": 10808, "split_mode": "include", "split_apps": []])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertEqual(route(cfg)["final"] as? String, "to-xray")
    }

    func test_ipv4_gets_slash32_and_ipv6_gets_slash128() throws {
        let p = try validate(["socks_port": 10808, "exclude_ips": ["1.2.3.4", "2001:db8::1"]])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        let tun = (cfg["inbounds"] as! [[String: Any]])[0]
        XCTAssertEqual(tun["route_exclude_address"] as? [String],
                       ["1.2.3.4/32", "2001:db8::1/128"])
    }

    func test_empty_split_apps_produce_no_process_name_rule() throws {
        let p = try validate(["socks_port": 10808, "split_mode": "exclude", "split_apps": []])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertEqual(rules(cfg).count, 1)
    }

    func test_split_off_ignores_the_app_list() throws {
        let p = try validate(["socks_port": 10808, "split_mode": "off",
                              "split_apps": ["Safari"]])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertEqual(rules(cfg).count, 1)
        XCTAssertEqual(route(cfg)["final"] as? String, "to-xray")
    }

    func test_tun_inbound_matches_the_python_version_field_for_field() throws {
        let p = try validate(["socks_port": 10808, "stack": "system"])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        let tun = (cfg["inbounds"] as! [[String: Any]])[0]
        XCTAssertEqual(tun["type"] as? String, "tun")
        XCTAssertEqual(tun["tag"] as? String, "tun-in")
        XCTAssertEqual(tun["address"] as? [String], ["172.18.0.1/30"])
        XCTAssertEqual(tun["mtu"] as? Int, 1500)
        XCTAssertEqual(tun["auto_route"] as? Bool, true)
        XCTAssertEqual(tun["stack"] as? String, "system")
        // Ни strict_route, ни interface_name: первого на darwin нет вовсе,
        // второе именует ядро.
        XCTAssertNil(tun["strict_route"])
        XCTAssertNil(tun["interface_name"])
    }

    func test_outbounds_carry_the_socks_port() throws {
        let p = try validate(["socks_port": 10999])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        XCTAssertEqual(outbounds[0]["tag"] as? String, "to-xray")
        XCTAssertEqual(outbounds[0]["type"] as? String, "socks")
        XCTAssertEqual(outbounds[0]["server"] as? String, "127.0.0.1")
        XCTAssertEqual(outbounds[0]["server_port"] as? Int, 10999)
        XCTAssertEqual(outbounds[0]["version"] as? String, "5")
        XCTAssertEqual(outbounds[1]["tag"] as? String, "direct")
    }

    func test_auto_detect_interface_is_on_and_log_level_carries_over() throws {
        let p = try validate(["socks_port": 10808, "log_level": "debug"])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertEqual(route(cfg)["auto_detect_interface"] as? Bool, true)
        XCTAssertEqual((cfg["log"] as! [String: Any])["level"] as? String, "debug")
    }

    func test_config_survives_json_serialization() throws {
        // Конфиг уезжает на диск через JSONSerialization: любой Swift-тип,
        // который она не знает, обрушил бы запись уже внутри демона, от root.
        let p = try validate(["socks_port": 10808, "split_mode": "include",
                              "split_apps": ["Safari"], "exclude_ips": ["1.2.3.4"]])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(cfg))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: cfg))
    }
}
