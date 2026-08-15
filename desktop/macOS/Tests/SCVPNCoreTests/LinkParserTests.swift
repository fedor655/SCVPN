import XCTest
@testable import SCVPNCore

final class LinkParserTests: XCTestCase {

    func test_parses_every_link_form_from_the_fixture() throws {
        for f in linkFixtures {
            let s = try XCTUnwrap(parseLink(f.link), f.note)
            XCTAssertEqual(s.proto, f.proto, f.note)
            XCTAssertEqual(s.address, f.address, f.note)
            XCTAssertEqual(s.port, f.port, f.note)
            XCTAssertEqual(s.name, f.name, f.note)
        }
    }

    func test_returns_nil_on_garbage_instead_of_crashing() {
        XCTAssertNil(parseLink("не ссылка"))
        XCTAssertNil(parseLink(""))
        XCTAssertNil(parseLink("   "))
        XCTAssertNil(parseLink("vless://"))
        XCTAssertNil(parseLink("vmess://%%%"))
        XCTAssertNil(parseLink("vmess://" + "bm90IGpzb24"))   // base64 не от JSON
        XCTAssertNil(parseLink("ss://"))
        XCTAssertNil(parseLink("https://example.com"))
    }

    func test_base64_without_padding_decodes() throws {
        XCTAssertEqual(String(decoding: try b64decode("YWJj"), as: UTF8.self), "abc")
        XCTAssertEqual(String(decoding: try b64decode("YWJjZA"), as: UTF8.self), "abcd")
        XCTAssertEqual(String(decoding: try b64decode("YWJjZGU"), as: UTF8.self), "abcde")
    }

    func test_base64_accepts_url_safe_alphabet() throws {
        // Панели шлют и url-safe: '-' и '_' вместо '+' и '/'.
        let standard = Data([0xfb, 0xff, 0xbf]).base64EncodedString()      // "+/+/"
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(try b64decode(urlSafe), Data([0xfb, 0xff, 0xbf]))
    }

    func test_reality_fields_survive_the_parse() throws {
        let s = try XCTUnwrap(parseLink(linkFixtures[0].link))
        XCTAssertEqual(s.security, "reality")
        XCTAssertEqual(s.flow, "xtls-rprx-vision")
        XCTAssertEqual(s.sni, "www.microsoft.com")
        XCTAssertEqual(s.fingerprint, "chrome")
        XCTAssertEqual(s.publicKey, "abcdef")
        XCTAssertEqual(s.shortID, "0123")
        XCTAssertEqual(s.spiderX, "/")
    }

    func test_percent_escapes_in_path_are_decoded_exactly_once() throws {
        // `path=%2Fws%3Fed%3D2048` обязан приехать как `/ws?ed=2048`.
        // Раскодировать дважды значило бы разрезать это на параметры запроса.
        let s = try XCTUnwrap(parseLink(linkFixtures[1].link))
        XCTAssertEqual(s.wsPath, "/ws?ed=2048")
        XCTAssertEqual(s.wsHost, "cdn.example.org")
        XCTAssertEqual(s.network, "ws")
    }

    func test_trojan_password_with_unescaped_at_is_split_on_the_last_one() throws {
        let s = try XCTUnwrap(parseLink("trojan://has@inside@trojan.example.com:443#Собака"))
        XCTAssertEqual(s.password, "has@inside")
        XCTAssertEqual(s.address, "trojan.example.com")
    }

    func test_trojan_defaults_to_tls_not_none() throws {
        // Без TLS trojan не работает вовсе, поэтому у него умолчание другое,
        // чем у vless.
        let s = try XCTUnwrap(parseLink("trojan://pass@a.b:443#x"))
        XCTAssertEqual(s.security, "tls")
    }

    func test_vmess_reads_string_port_and_numeric_alter_id() throws {
        let s = try XCTUnwrap(parseLink(linkFixtures[5].link))
        XCTAssertEqual(s.port, 443)         // в JSON лежит строкой "443"
        XCTAssertEqual(s.alterID, 0)
        XCTAssertEqual(s.network, "ws")
        XCTAssertEqual(s.security, "tls")
        XCTAssertEqual(s.wsPath, "/path")
        XCTAssertEqual(s.wsHost, "vmess.example.com")
    }

    func test_shadowsocks_reads_both_legal_forms() throws {
        let a = try XCTUnwrap(parseLink(linkFixtures[6].link))
        XCTAssertEqual(a.method, "aes-256-gcm")
        XCTAssertEqual(a.password, "secret")

        let b = try XCTUnwrap(parseLink(linkFixtures[7].link))
        XCTAssertEqual(b.method, "aes-256-gcm")
        XCTAssertEqual(b.password, "secret")
        XCTAssertEqual(b.port, 9999)
    }

    func test_ipv6_host_keeps_no_brackets() throws {
        let s = try XCTUnwrap(parseLink(linkFixtures[2].link))
        XCTAssertEqual(s.address, "2001:db8::1")
        XCTAssertEqual(s.port, 443)
    }

    func test_subscription_text_reads_plain_list() {
        let text = linkFixtures.map(\.link).joined(separator: "\n")
        XCTAssertEqual(parseSubscriptionText(text).count, linkFixtures.count)
    }

    func test_subscription_text_reads_base64_list() {
        let text = linkFixtures.map(\.link).joined(separator: "\n")
        let encoded = Data(text.utf8).base64EncodedString()
        XCTAssertEqual(parseSubscriptionText(encoded).count, linkFixtures.count)
    }

    func test_subscription_text_skips_garbage_lines() {
        let text = """
        мусор
        \(linkFixtures[0].link)

        https://example.com
        \(linkFixtures[3].link)
        """
        // Одна кривая строка не должна стоить пользователю всей подписки.
        XCTAssertEqual(parseSubscriptionText(text).count, 2)
    }

    func test_empty_subscription_yields_no_servers() {
        XCTAssertTrue(parseSubscriptionText("").isEmpty)
        XCTAssertTrue(parseSubscriptionText("   \n  \n").isEmpty)
    }
}
