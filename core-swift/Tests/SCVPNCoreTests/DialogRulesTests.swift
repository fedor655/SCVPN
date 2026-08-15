import XCTest
@testable import SCVPNCore

/// Правила диалогов Задачи 6.5, которые держатся на коде, а не на разметке.
final class DialogRulesTests: StorageIsolatedTestCase {

    // ---- добавление: тип определяется по строке ----

    func test_link_is_recognised_before_falling_back_to_subscription() {
        // Одно поле на оба случая: спрашивать «это ссылка или подписка?»
        // значило бы перекладывать на человека то, что программа выясняет.
        XCTAssertNotNil(parseLink(linkFixtures[0].link))
        // URL подписки парсер ссылок не узнаёт — и не должен.
        XCTAssertNil(parseLink("https://panel.example.com/sub/abc"))
    }

    func test_a_subscription_url_is_http_only() {
        // Всё, что не ссылка сервера и не http(s), — не подписка, и говорить
        // об этом надо сразу, а не после похода в сеть.
        for value in ["ftp://example.com/sub", "просто текст", "/tmp/файл"] {
            XCTAssertNil(parseLink(value), value)
            XCTAssertFalse(value.hasPrefix("http://") || value.hasPrefix("https://"), value)
        }
    }

    #if os(macOS)
    // ---- раздельное туннелирование ----

    func test_auto_is_a_routing_mode_not_an_app_split() {
        // «Авто» задаётся route_mode, а не split_mode. Сохрани его вторым —
        // и туннель поднялся бы не тем, чем просили.
        XCTAssertEqual(RouteMode.bypassRU.rawValue, "bypass_ru")
        XCTAssertEqual(RouteMode.global.rawValue, "global")
        XCTAssertNil(SplitMode(rawValue: "bypass_ru"))
    }

    func test_split_off_ignores_apps_so_the_choice_is_recoverable() throws {
        // Список приложений переживает переключение на «всё через VPN»:
        // конфиг его игнорирует, а не требует очистки. Иначе выбор
        // пользователя терялся бы при каждом переключении режима.
        let p = try validate(["socks_port": 10808, "split_mode": "off",
                              "split_apps": ["Safari", "Telegram"]])
        XCTAssertEqual(p.splitApps, ["Safari", "Telegram"])
        let cfg = buildSingboxConfig(p, xrayPath: "/tmp/bin/xray")
        let rules = (cfg["route"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(rules.count, 1, "в режиме off правило по приложениям лишнее")
    }

    func test_manually_typed_app_names_are_normalised_before_saving() {
        // Человек вставляет путь или имя бандла; sing-box ждёт имя
        // исполняемого файла внутри бандла.
        XCTAssertEqual(RunningApps.normalizeAppName("/Applications/Telegram.app"), "Telegram")
        XCTAssertEqual(RunningApps.normalizeAppName(" Safari.app "), "Safari")
    }

    func test_normalised_name_passes_daemon_validation() throws {
        // То, что диалог сохранит, обязано пройти проверку демона: иначе
        // отказ вылезет уже при подключении, а не при выборе.
        let name = RunningApps.normalizeAppName("/Applications/Telegram.app")
        XCTAssertNoThrow(try validate(["socks_port": 10808, "split_apps": [name]]))
        // А путь целиком демон отвергнет — и правильно.
        XCTAssertThrowsError(try validate(["socks_port": 10808,
                                           "split_apps": ["/Applications/Telegram.app"]]))
    }
    #endif

    // ---- подписки ----

    func test_subscription_card_shows_what_the_panel_sent_and_nothing_else() {
        // Даты активации в заголовках не бывает, поэтому в модели её нет и
        // придумывать её диалогу не из чего.
        var info = SubscriptionInfo()
        info.expire = 0
        XCTAssertNil(info.expiresAt)
        XCTAssertNil(info.daysLeft)
        XCTAssertTrue(info.unlimited)
        XCTAssertEqual(humanInterval(info.updateInterval), "не задано")
    }

    func test_traffic_line_reads_the_same_way_in_both_cases() {
        var info = SubscriptionInfo()
        info.download = 3 << 30
        XCTAssertEqual(humanBytes(info.used), "3.00 ГБ")
        info.total = 10 << 30
        XCTAssertFalse(info.unlimited)
        XCTAssertEqual(info.usedRatio, 0.3, accuracy: 0.001)
    }
}
