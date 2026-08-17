import XCTest
@testable import SCVPNCore

/// Разбор AmneziaWG и его путь до конфига Xray.
///
/// Ключи здесь сгенерированы для проверки и никуда не ведут: приватный ключ
/// туннеля — это пароль от всего трафика, и настоящему в репозитории не место.
final class WireGuardTests: XCTestCase {

    private let privateKey = "38GCTbJEvBrai7BT7K8SzCJbD92q35iwl98JRQb/gqI="
    private let publicKey = "DdoK6OyIth4BjEvyRBnH7eUpjOniDyUMiodwzE5CEl8="
    private let psk = "zxrL/zVlGsR8kjYEg5uS7Krt9XmrgNjliUk6NDvaTEE="

    private var conf: String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.66.66.4/32,fd42:42:42::4/128
        DNS = 1.1.1.1,1.0.0.1
        Jc = 10
        Jmin = 47
        Jmax = 129
        S1 = 46
        S2 = 30
        S3 = 19
        S4 = 18
        H1 = 1035708199
        H2 = 256240833
        H3 = 1997207975
        H4 = 556935419

        [Peer]
        PublicKey = \(publicKey)
        PresharedKey = \(psk)
        Endpoint = 198.51.100.7:51820
        AllowedIPs = 0.0.0.0/0,::/0
        PersistentKeepalive = 25
        """
    }

    func test_conf_parses_into_a_server() throws {
        let s = try XCTUnwrap(parseWireGuardConf(conf, name: "Фёдор"))
        XCTAssertEqual(s.proto, "wireguard")
        XCTAssertEqual(s.name, "Фёдор")
        XCTAssertEqual(s.address, "198.51.100.7")
        XCTAssertEqual(s.port, 51820)
        XCTAssertEqual(s.privateKey, privateKey)
        XCTAssertEqual(s.publicKey, publicKey)
        XCTAssertEqual(s.presharedKey, psk)
        XCTAssertEqual(s.localAddress, "10.66.66.4/32,fd42:42:42::4/128")
        XCTAssertEqual(s.allowedIPs, "0.0.0.0/0,::/0")
        XCTAssertEqual(s.wgDNS, "1.1.1.1,1.0.0.1")
        XCTAssertEqual(s.keepalive, 25)
        XCTAssertEqual(s.awg, "jc=10,jmin=47,jmax=129,s1=46,s2=30,s3=19,s4=18,"
                       + "h1=1035708199,h2=256240833,h3=1997207975,h4=556935419")
    }

    /// Круг «разобрать — собрать — разобрать» обязан сойтись: собранный файл
    /// уходит процессу `scvpn-awg`, и потеря поля здесь означала бы туннель,
    /// который поднимается не по тому конфигу, что показан пользователю.
    func test_conf_survives_a_round_trip() throws {
        let first = try XCTUnwrap(parseWireGuardConf(conf))
        let again = try XCTUnwrap(parseWireGuardConf(wireGuardConfText(first)))
        XCTAssertEqual(first, again)
    }

    func test_plain_wireguard_needs_no_obfuscation() throws {
        let s = try XCTUnwrap(parseWireGuardConf("""
            [Interface]
            PrivateKey = \(privateKey)
            Address = 10.0.0.2/32
            [Peer]
            PublicKey = \(publicKey)
            Endpoint = vpn.example.com:51820
            """))
        XCTAssertTrue(s.awg.isEmpty, "обфускации не было, а поле заполнено")
        // Пустой AllowedIPs у wg-quick значит «ничего не маршрутизировать»:
        // туннель поднялся бы и не пропустил ни байта.
        XCTAssertEqual(s.allowedIPs, "0.0.0.0/0,::/0")
        XCTAssertEqual(s.address, "vpn.example.com")
    }

    func test_broken_conf_returns_nil_instead_of_a_dead_server() {
        XCTAssertNil(parseWireGuardConf(""))
        XCTAssertNil(parseWireGuardConf("не конфиг"))
        // Обрезанный ключ ядро приняло бы молча, а туннель не поднялся бы.
        XCTAssertNil(parseWireGuardConf("[Interface]\nPrivateKey = YWJj\nAddress = 10.0.0.2/32\n"
                                        + "[Peer]\nPublicKey = \(publicKey)\nEndpoint = 1.2.3.4:1"))
        // Без Endpoint соединяться не с чем.
        XCTAssertNil(parseWireGuardConf("[Interface]\nPrivateKey = \(privateKey)\n"
                                        + "Address = 10.0.0.2/32\n[Peer]\nPublicKey = \(publicKey)"))
        // Без Address интерфейсу нечего присвоить.
        XCTAssertNil(parseWireGuardConf("[Interface]\nPrivateKey = \(privateKey)\n"
                                        + "[Peer]\nPublicKey = \(publicKey)\nEndpoint = 1.2.3.4:1"))
    }

    func test_link_form_matches_the_conf_form() throws {
        // Однострочная форма нужна подписке: та строго по серверу на строку.
        // Приватный ключ в userinfo панели шлют в url-safe алфавите, публичный
        // в параметре — процентами: обе формы обязаны развернуться обратно.
        let urlSafe = privateKey
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let escaped = publicKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let link = "wireguard://" + urlSafe + "@198.51.100.7:51820"
            + "?publickey=" + escaped
            + "&address=10.66.66.4%2F32&jc=10&jmin=47#WG"
        let s = try XCTUnwrap(parseLink(link))
        XCTAssertEqual(s.proto, "wireguard")
        XCTAssertEqual(s.privateKey, privateKey)
        XCTAssertEqual(s.publicKey, publicKey)
        XCTAssertEqual(s.address, "198.51.100.7")
        XCTAssertEqual(s.port, 51820)
        XCTAssertEqual(s.localAddress, "10.66.66.4/32")
        XCTAssertEqual(s.awg, "jc=10,jmin=47")
        XCTAssertEqual(s.name, "WG")
    }

    func test_outbound_points_xray_at_the_local_tunnel() throws {
        let s = try XCTUnwrap(parseWireGuardConf(conf))
        let out = try s.toOutbound(tag: "proxy", awgSocksPort: 10810)

        // Xray ходит в туннель как в обычный SOCKS: обфускацию он не умеет, её
        // делает отдельный процесс. Отсюда protocol socks, а не wireguard.
        XCTAssertEqual(out["protocol"] as? String, "socks")
        let servers = try XCTUnwrap((out["settings"] as? [String: Any])?["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.first?["address"] as? String, "127.0.0.1")
        XCTAssertEqual(servers.first?["port"] as? Int, 10810)
        // streamSettings у socks-выхода на localhost значит транспорт до
        // localhost — вписывать туда ws или reality было бы бессмыслицей.
        XCTAssertNil(out["streamSettings"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(out))
    }

    func test_whole_xray_config_builds_for_a_wireguard_server() throws {
        let s = try XCTUnwrap(parseWireGuardConf(conf))
        let cfg = try buildXrayConfig(server: s, awgPort: 10810, geoAssets: false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(cfg))
        // Маршрутизация и DNS остаются прежними — в этом весь смысл того, что
        // туннель отдаётся именно SOCKS-ом.
        XCTAssertNotNil(cfg["routing"])
        XCTAssertNotNil(cfg["dns"])
    }

    func test_two_peers_on_one_endpoint_do_not_collapse_into_one_key() throws {
        // У wireguard нет ни uuid, ни пароля, и без публичного ключа в key()
        // два разных пира на одном host:port стали бы одной строкой списка и
        // одним selected_key.
        var a = try XCTUnwrap(parseWireGuardConf(conf))
        var b = a
        b.publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        XCTAssertNotEqual(a.key(), b.key())

        // А ключи прежних протоколов формат не меняют.
        a = Server(proto: "vless", address: "example.com", port: 443, uuid: "u")
        XCTAssertEqual(a.key(), "vless://u@example.com:443/tcp/none")
    }

    /// Старый клиент читает новый файл, новый — старый.
    ///
    /// Формат `profiles.json` один на все платформы, и обновляются они не
    /// одновременно.
    func test_profiles_json_stays_compatible_in_both_directions() throws {
        let wg = try XCTUnwrap(parseWireGuardConf(conf, name: "Фёдор"))
        let encoded = try JSONEncoder().encode(wg)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? String, "wireguard")
        XCTAssertEqual(object["private_key"] as? String, privateKey)
        XCTAssertEqual(object["local_address"] as? String, "10.66.66.4/32,fd42:42:42::4/128")
        XCTAssertNotNil(object["awg"])
        XCTAssertEqual(try JSONDecoder().decode(Server.self, from: encoded), wg)

        // У обычного сервера новых ключей в файле не появляется: иначе первое
        // же сохранение переписало бы профиль, принесённый с другой платформы.
        let vless = Server(proto: "vless", address: "example.com", uuid: "u")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(vless)) as? [String: Any])
        for key in ["private_key", "preshared_key", "local_address",
                    "allowed_ips", "wg_dns", "mtu", "keepalive", "awg"] {
            XCTAssertNil(plain[key], "у не-wireguard сервера появился ключ \(key)")
        }
    }
}
