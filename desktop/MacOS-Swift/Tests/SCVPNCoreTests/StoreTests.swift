import XCTest
@testable import SCVPNCore

final class StoreTests: StorageIsolatedTestCase {

    private func write(settingsJSON: String) throws {
        try Data(settingsJSON.utf8).write(to: Paths.settingsFile)
    }

    func test_unknown_settings_keys_survive_a_round_trip() throws {
        // Ключ hwid пишет в settings.json отдельный модуль, и в
        // defaultSettings его нет. Структура с фиксированными полями потеряла
        // бы его при первом же сохранении, а пользователь занял бы новый слот
        // в лимите устройств панели.
        try withTempDataDir { _ in
            try write(settingsJSON: #"{"hwid": "ab-cd", "новый_ключ": 42}"#)
            var s = loadSettings()
            s["block_ads"] = .bool(true)
            saveSettings(s)

            let again = loadSettings()
            XCTAssertEqual(again["hwid"], .string("ab-cd"))
            XCTAssertEqual(again["новый_ключ"], .int(42))
            XCTAssertEqual(again["block_ads"], .bool(true))
        }
    }

    func test_missing_file_yields_defaults() {
        withTempDataDir { _ in
            XCTAssertEqual(loadSettings()["tun_stack"], .string("gvisor"))
            XCTAssertEqual(loadSettings()["socks_port"], .int(10808))
            XCTAssertEqual(loadSettings()["vpn_mode"], .string("proxy"))
        }
    }

    func test_corrupted_file_yields_defaults_without_crashing() throws {
        try withTempDataDir { _ in
            try write(settingsJSON: "{это не json")
            XCTAssertEqual(loadSettings()["socks_port"], .int(10808))
        }
    }

    func test_saved_file_stays_human_readable() throws {
        // Файлы открывают текстовым редактором. Превращение русских имён в
        // \uXXXX разбор не ломает, но формат на диске заморожен именно как
        // читаемый.
        try withTempDataDir { _ in
            saveSettings(["имя": .string("Нидерланды"), "путь": .string("/ws")])
            let text = try String(contentsOf: Paths.settingsFile, encoding: .utf8)
            XCTAssertTrue(text.contains("Нидерланды"), text)
            XCTAssertTrue(text.contains("/ws"), text)
            XCTAssertFalse(text.contains("\\u"), text)
            XCTAssertFalse(text.contains("\\/"), text)
        }
    }

    func test_booleans_do_not_decay_into_numbers() throws {
        // JSONValue разбирает Bool раньше Int намеренно: `true`, уехавший
        // обратно единицей, сломал бы формат на диске.
        try withTempDataDir { _ in
            try write(settingsJSON: #"{"block_ads": true, "http_port": 1}"#)
            let s = loadSettings()
            XCTAssertEqual(s["block_ads"], .bool(true))
            XCTAssertEqual(s["http_port"], .int(1))
            saveSettings(s)
            let text = try String(contentsOf: Paths.settingsFile, encoding: .utf8)
            XCTAssertTrue(text.contains("\"block_ads\" : true"), text)
        }
    }

    func test_profiles_round_trip_keeps_every_field() throws {
        try withTempDataDir { _ in
            var server = Server(proto: "vless", name: "Нидерланды", address: "a.b",
                                port: 443, uuid: "u", network: "ws", security: "reality")
            server.extra = ["своё": .string("значение")]
            var sub = Subscription(name: "Подписка", url: "https://x/y",
                                   updated: "2026-08-15 10:00", added: "2026-08-01 09:00")
            sub.servers = [server]
            sub.info.total = 100
            sub.info.download = 25
            sub.info.hwid = ["x-hwid-max-devices-reached": "true"]

            saveProfiles(Profiles(subscriptions: [sub], servers: [server]))
            let back = loadProfiles()

            XCTAssertEqual(back.servers.first, server)
            XCTAssertEqual(back.subscriptions.first?.name, "Подписка")
            XCTAssertEqual(back.subscriptions.first?.info.total, 100)
            XCTAssertTrue(back.subscriptions.first?.info.deviceLimitReached == true)
            XCTAssertEqual(back.allServers().count, 2)
        }
    }

    func test_profiles_file_uses_the_python_key_names() throws {
        try withTempDataDir { _ in
            let s = Server(proto: "vless", address: "a.b", alterID: 7,
                           publicKey: "pbk", shortID: "sid", allowInsecure: true,
                           wsPath: "/w", wsHost: "h", grpcService: "g")
            saveProfiles(Profiles(servers: [s]))
            let text = try String(contentsOf: Paths.profilesFile, encoding: .utf8)
            // Имена ключей — содержимое profiles.json у пользователя. Любая
            // правка молча теряет поле при следующем чтении.
            for key in ["\"protocol\"", "\"alter_id\"", "\"public_key\"", "\"short_id\"",
                        "\"allow_insecure\"", "\"ws_path\"", "\"ws_host\"", "\"grpc_service\"",
                        "\"spider_x\""] {
                XCTAssertTrue(text.contains(key), "нет ключа \(key) в:\n\(text)")
            }
            XCTAssertFalse(text.contains("\"proto\""), text)
        }
    }

    func test_profiles_read_a_file_written_by_an_older_version() throws {
        // Файл прежней версии, где половины полей ещё не было: разбор обязан
        // подставить умолчания, а не отказаться читать профили целиком.
        try withTempDataDir { _ in
            let old = #"{"servers": [{"protocol": "vless", "address": "a.b", "port": 443}]}"#
            try Data(old.utf8).write(to: Paths.profilesFile)
            let p = loadProfiles()
            XCTAssertEqual(p.servers.count, 1)
            XCTAssertEqual(p.servers[0].network, "tcp")
            XCTAssertEqual(p.servers[0].spiderX, "/")
        }
    }

    func test_corrupted_profiles_yield_empty_not_a_crash() throws {
        try withTempDataDir { _ in
            try Data("{сломано".utf8).write(to: Paths.profilesFile)
            XCTAssertTrue(loadProfiles().allServers().isEmpty)
        }
    }

    func test_all_servers_puts_standalone_first() {
        let a = Server(proto: "vless", name: "одиночный", address: "a")
        let b = Server(proto: "vless", name: "из подписки", address: "b")
        let p = Profiles(subscriptions: [Subscription(servers: [b])], servers: [a])
        // Порядок значим: по нему строится список на экране.
        XCTAssertEqual(p.allServers().map(\.name), ["одиночный", "из подписки"])
    }
}
