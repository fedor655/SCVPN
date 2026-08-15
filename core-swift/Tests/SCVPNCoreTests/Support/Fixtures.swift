import Foundation
import XCTest
@testable import SCVPNCore

/// Базовый класс для проверок, которые могут дотянуться до диска.
///
/// Заведён по факту: `test_bad_url_is_refused_before_the_network` через
/// `deviceHeaders()` -> `deviceID()` записал настоящий
/// `~/Library/Application Support/SCVPN/settings.json` пользователя. Пути к
/// записи прячутся глубоко, и полагаться на то, что каждый автор проверки о них
/// вспомнит, нельзя — поэтому подмена корня стоит в `setUp`, а не в теле
/// проверки. `withTempDataDir` для асинхронных проверок не годится: он
/// восстанавливает путь по выходу из синхронного замыкания.
class StorageIsolatedTestCase: XCTestCase {
    private var savedDataDir: URL!
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedDataDir = Paths.dataDir
        tmp = URL(fileURLWithPath: "/tmp/scvpn-core-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        Paths.dataDir = tmp
    }

    override func tearDownWithError() throws {
        Paths.dataDir = savedDataDir
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }
}

/// Временный корень данных на время синхронного замыкания.
///
/// `Paths.dataDir` — переменная именно ради этого: без подмены проверки писали
/// бы в настоящие `profiles.json` и `settings.json` пользователя, то есть
/// стирали бы его подписки при каждом прогоне.
func withTempDataDir(_ body: (URL) throws -> Void) rethrows {
    let saved = Paths.dataDir
    let tmp = URL(fileURLWithPath: "/tmp/scvpn-core-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    Paths.dataDir = tmp
    defer {
        Paths.dataDir = saved
        try? FileManager.default.removeItem(at: tmp)
    }
    try body(tmp)
}

/// Ссылки, встречавшиеся живьём. План предлагал взять их из
/// `desktop/MacOS/smoke_test.py`, но там их нет: тот скрипт читает настоящий
/// `profiles.json` пользователя, а литералов ссылок не содержит. Набор собран
/// по формам, которые разбирает `shared/subscription.py`, включая те, ради
/// которых там стоят отдельные ветки.
struct LinkFixture {
    let link: String
    let proto: String
    let address: String
    let port: Int
    let name: String
    let note: String
}

let linkFixtures: [LinkFixture] = [
    LinkFixture(
        link: "vless://11111111-2222-3333-4444-555555555555@example.com:443"
            + "?type=tcp&security=reality&flow=xtls-rprx-vision&sni=www.microsoft.com"
            + "&fp=chrome&pbk=abcdef&sid=0123&spx=%2F#%D0%9D%D0%B8%D0%B4%D0%B5%D1%80%D0%BB%D0%B0%D0%BD%D0%B4%D1%8B",
        proto: "vless", address: "example.com", port: 443, name: "Нидерланды",
        note: "reality с русским именем в #fragment"),

    LinkFixture(
        link: "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:8443"
            + "?type=ws&security=tls&sni=cdn.example.org&path=%2Fws%3Fed%3D2048&host=cdn.example.org#WS",
        proto: "vless", address: "1.2.3.4", port: 8443, name: "WS",
        note: "ws с процентами внутри path"),

    LinkFixture(
        link: "vless://aaaa@[2001:db8::1]:443?type=tcp&security=none#IPv6",
        proto: "vless", address: "2001:db8::1", port: 443, name: "IPv6",
        note: "IPv6-литерал в квадратных скобках"),

    LinkFixture(
        link: "trojan://p%40ssw0rd@trojan.example.com:443?sni=trojan.example.com#Trojan",
        proto: "trojan", address: "trojan.example.com", port: 443, name: "Trojan",
        note: "пароль с экранированной собакой"),

    LinkFixture(
        link: "trojan://has@inside@trojan.example.com:443#Собака",
        proto: "trojan", address: "trojan.example.com", port: 443, name: "Собака",
        note: "неэкранированная собака в пароле — режем по последней"),

    // vmess://base64({"v":"2","ps":"Токио","add":"vmess.example.com","port":"443",
    //   "id":"1111...","aid":"0","net":"ws","tls":"tls","host":"vmess.example.com",
    //   "path":"/path"})
    LinkFixture(
        link: "vmess://eyJ2IjoiMiIsInBzIjoi0KLQvtC60LjQviIsImFkZCI6InZtZXNzLmV4YW1wbGUuY29tIiwi"
            + "cG9ydCI6IjQ0MyIsImlkIjoiMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1Iiwi"
            + "YWlkIjoiMCIsIm5ldCI6IndzIiwidGxzIjoidGxzIiwiaG9zdCI6InZtZXNzLmV4YW1wbGUuY29t"
            + "IiwicGF0aCI6Ii9wYXRoIn0",
        proto: "vmess", address: "vmess.example.com", port: 443, name: "Токио",
        note: "base64-JSON без паддинга, порт строкой"),

    // ss://base64(aes-256-gcm:секрет)@ss.example.com:8388#SS
    LinkFixture(
        link: "ss://YWVzLTI1Ni1nY206c2VjcmV0@ss.example.com:8388#SS",
        proto: "shadowsocks", address: "ss.example.com", port: 8388, name: "SS",
        note: "userinfo в base64, хост открытым текстом"),

    // ss://base64(aes-256-gcm:secret@ss2.example.com:9999)#SS2
    LinkFixture(
        link: "ss://YWVzLTI1Ni1nY206c2VjcmV0QHNzMi5leGFtcGxlLmNvbTo5OTk5#SS2",
        proto: "shadowsocks", address: "ss2.example.com", port: 9999, name: "SS2",
        note: "целиком в base64 — вторая законная форма"),
]
