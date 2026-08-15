import XCTest
@testable import SCVPNCore

final class ModelTests: XCTestCase {

    func test_key_matches_python_format() {
        let s = Server(proto: "vless", address: "a.b", port: 443, uuid: "u",
                       network: "tcp", security: "reality")
        // Формат заморожен: ключ лежит в settings.json как selected_key, и
        // его смена потеряла бы выбранный сервер у каждого пользователя.
        XCTAssertEqual(s.key(), "vless://u@a.b:443/tcp/reality")
    }

    func test_key_falls_back_to_password_when_there_is_no_uuid() {
        let s = Server(proto: "trojan", address: "a.b", port: 443, password: "p",
                       network: "tcp", security: "tls")
        XCTAssertEqual(s.key(), "trojan://p@a.b:443/tcp/tls")
    }

    func test_title_falls_back_to_address_and_port() {
        XCTAssertEqual(Server(address: "a.b", port: 443).title, "a.b:443")
        XCTAssertEqual(Server(name: "Токио", address: "a.b", port: 443).title, "Токио")
    }

    func test_reality_outbound_defaults_fingerprint_to_chrome() throws {
        // Пустой отпечаток означает «панель его не прислала», а не «отпечаток
        // не нужен»: Reality без uTLS не работает.
        var s = Server(proto: "vless", security: "reality")
        s.fingerprint = ""
        let out = try s.toOutbound(tag: "proxy")
        let ss = out["streamSettings"] as! [String: Any]
        let reality = ss["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
    }

    func test_reality_keeps_an_explicit_fingerprint() throws {
        var s = Server(proto: "vless", security: "reality")
        s.fingerprint = "firefox"
        let ss = try s.toOutbound()["streamSettings"] as! [String: Any]
        XCTAssertEqual((ss["realitySettings"] as! [String: Any])["fingerprint"] as? String,
                       "firefox")
    }

    func test_tls_server_name_falls_back_to_address() throws {
        var s = Server(proto: "vless", address: "a.b", security: "tls")
        s.sni = ""
        let ss = try s.toOutbound()["streamSettings"] as! [String: Any]
        XCTAssertEqual((ss["tlsSettings"] as! [String: Any])["serverName"] as? String, "a.b")
    }

    func test_alpn_is_split_and_trimmed() throws {
        var s = Server(proto: "vless", security: "tls")
        s.alpn = "h2, http/1.1 ,"
        let ss = try s.toOutbound()["streamSettings"] as! [String: Any]
        XCTAssertEqual((ss["tlsSettings"] as! [String: Any])["alpn"] as? [String],
                       ["h2", "http/1.1"])
    }

    func test_vless_flow_appears_only_when_set() throws {
        var s = Server(proto: "vless", uuid: "u")
        var vnext = ((try s.toOutbound()["settings"] as! [String: Any])["vnext"] as! [[String: Any]])[0]
        var user = (vnext["users"] as! [[String: Any]])[0]
        XCTAssertNil(user["flow"])

        s.flow = "xtls-rprx-vision"
        vnext = ((try s.toOutbound()["settings"] as! [String: Any])["vnext"] as! [[String: Any]])[0]
        user = (vnext["users"] as! [[String: Any]])[0]
        XCTAssertEqual(user["flow"] as? String, "xtls-rprx-vision")
    }

    func test_ws_host_header_falls_back_to_sni() throws {
        var s = Server(proto: "vless", network: "ws")
        s.sni = "cdn.example.org"
        let ss = try s.toOutbound()["streamSettings"] as! [String: Any]
        let ws = ss["wsSettings"] as! [String: Any]
        XCTAssertEqual((ws["headers"] as! [String: String])["Host"], "cdn.example.org")
    }

    func test_unknown_protocol_throws() {
        XCTAssertThrowsError(try Server(proto: "неизвестный").toOutbound(tag: "proxy"))
    }

    func test_every_protocol_produces_serializable_output() throws {
        for proto in ["vless", "vmess", "trojan", "shadowsocks"] {
            let out = try Server(proto: proto, address: "a.b", uuid: "u",
                                 password: "p", method: "aes-256-gcm").toOutbound()
            XCTAssertTrue(JSONSerialization.isValidJSONObject(out), proto)
        }
    }

    func test_subscription_info_derived_values() {
        var info = SubscriptionInfo()
        info.upload = 30; info.download = 70; info.total = 200
        XCTAssertEqual(info.used, 100)
        XCTAssertFalse(info.unlimited)
        XCTAssertEqual(info.usedRatio, 0.5, accuracy: 0.0001)

        info.total = 0
        XCTAssertTrue(info.unlimited)
        XCTAssertEqual(info.usedRatio, 0)      // при безлимите доля не считается

        info.total = 50                        // перерасход не даёт больше единицы
        XCTAssertEqual(info.usedRatio, 1.0, accuracy: 0.0001)
    }

    func test_expiry_is_nil_when_subscription_is_perpetual() {
        var info = SubscriptionInfo()
        XCTAssertNil(info.expiresAt)
        XCTAssertNil(info.daysLeft)
        info.expire = Int(Date().addingTimeInterval(3 * 86400 + 60).timeIntervalSince1970)
        XCTAssertEqual(info.daysLeft, 3)
    }

    func test_parses_subscription_userinfo_header() {
        let info = subscriptionInfo(from: [
            "subscription-userinfo": "upload=0; download=123; total=0; expire=1788405825",
            "profile-update-interval": "24",
            "content-disposition": "attachment; filename=F_Semin_key-1",
        ])
        XCTAssertEqual(info.download, 123)
        XCTAssertTrue(info.unlimited)
        XCTAssertEqual(info.updateInterval, 24)
        XCTAssertEqual(info.account, "F_Semin_key-1")
        XCTAssertEqual(info.expire, 1788405825)
    }

    func test_header_names_are_matched_case_insensitively() {
        // HTTP-заголовки регистронезависимы, и панели пишут их вразнобой.
        let info = subscriptionInfo(from: ["Profile-Update-Interval": "12",
                                           "SUBSCRIPTION-USERINFO": "total=99"])
        XCTAssertEqual(info.updateInterval, 12)
        XCTAssertEqual(info.total, 99)
    }

    func test_float_values_in_userinfo_do_not_get_dropped() {
        // Панели присылают и `0`, и `0.0`; строгий разбор целого потерял бы
        // второе молча.
        let info = subscriptionInfo(from: ["subscription-userinfo": "download=123.0; total=5.9"])
        XCTAssertEqual(info.download, 123)
        XCTAssertEqual(info.total, 5)
    }

    func test_decodes_base64_profile_title() {
        let info = subscriptionInfo(from: ["profile-title": "base64:0J/RgNC+0YTQuNC70Yw="])
        XCTAssertEqual(info.title, "Профиль")
    }

    func test_plain_profile_title_is_left_alone() {
        XCTAssertEqual(subscriptionInfo(from: ["profile-title": "Мой профиль"]).title,
                       "Мой профиль")
    }

    func test_hwid_headers_are_collected() {
        let info = subscriptionInfo(from: ["x-hwid-max-devices-reached": "true",
                                           "x-hwid-device-limit": "3",
                                           "content-type": "text/plain"])
        XCTAssertTrue(info.deviceLimitReached)
        XCTAssertEqual(info.hwid.count, 2)
        XCTAssertNil(info.hwid["content-type"])
    }

    func test_human_bytes_matches_python() {
        XCTAssertEqual(humanBytes(0), "0 Б")
        XCTAssertEqual(humanBytes(-5), "0 Б")
        XCTAssertEqual(humanBytes(512), "512 Б")
        XCTAssertEqual(humanBytes(1 << 10), "1.00 КБ")
        XCTAssertEqual(humanBytes(3 << 30), "3.00 ГБ")
    }

    func test_human_interval_matches_python() {
        XCTAssertEqual(humanInterval(0), "не задано")
        XCTAssertEqual(humanInterval(24), "раз в сутки")
        XCTAssertEqual(humanInterval(48), "раз в 2 дн.")
        XCTAssertEqual(humanInterval(6), "раз в 6 ч.")
    }
}
