import XCTest
@testable import SCVPNCore

final class ConnectionStateTests: XCTestCase {

    func test_tun_stuck_is_not_the_same_as_error() {
        // Ошибка подключения и «отключиться не вышло» — разные новости, и
        // вторая опаснее: трафик продолжает идти в туннель, которым никто не
        // управляет. Слить их в одно состояние значит потерять это различие.
        XCTAssertNotEqual(ConnectionState.tunStuck, .error)
        XCTAssertNotEqual(ConnectionState.tunStuck.title, ConnectionState.error.title)
        XCTAssertEqual(ConnectionState.tunStuck.rawValue, "tun_stuck")
    }

    func test_every_state_has_its_own_wording() {
        let titles = ConnectionState.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "два состояния подписаны одинаково")
        XCTAssertFalse(titles.contains { $0.isEmpty })
    }

    func test_states_differ_by_shape_not_only_by_brightness() {
        // В чёрно-белой теме цвет различает мало что. Проверяем, что каждая
        // пара состояний отличается хотя бы одним из: цветом, толщиной,
        // пунктиром. Иначе «подключено» и «ошибка» читались бы одинаково.
        let all = ConnectionState.allCases
        for a in all {
            for b in all where a != b {
                let x = a.ring, y = b.ring
                XCTAssertTrue(x.color != y.color || x.width != y.width || x.dashed != y.dashed,
                              "\(a) и \(b) неотличимы на вид")
            }
        }
    }

    func test_connected_and_stuck_share_thickness_but_not_the_dash() {
        // Толщина одна: трафик и правда идёт через VPN. Пунктир говорит, что
        // это не рабочее состояние, а то, что надо разбирать.
        XCTAssertEqual(ConnectionState.connected.ring.width,
                       ConnectionState.tunStuck.ring.width)
        XCTAssertFalse(ConnectionState.connected.ring.dashed)
        XCTAssertTrue(ConnectionState.tunStuck.ring.dashed)
    }

    func test_ping_without_an_answer_is_spelled_out() {
        // Одной яркости для такого случая мало — подписываем словами.
        XCTAssertEqual(pingLabel(.noAnswer).text, "нет ответа")
        XCTAssertEqual(pingLabel(.unknown).text, "")
    }

    func test_ping_gets_dimmer_as_it_grows() {
        XCTAssertEqual(pingLabel(.ms(50)).color, Palette.text)
        XCTAssertEqual(pingLabel(.ms(300)).color, Palette.dim)
        XCTAssertEqual(pingLabel(.ms(900)).color, Palette.muted)
        XCTAssertEqual(pingLabel(.ms(50)).text, "50 мс")
    }

    func test_ping_thresholds_are_where_the_python_had_them() {
        XCTAssertEqual(pingLabel(.ms(199)).color, Palette.text)
        XCTAssertEqual(pingLabel(.ms(200)).color, Palette.dim)
        XCTAssertEqual(pingLabel(.ms(499)).color, Palette.dim)
        XCTAssertEqual(pingLabel(.ms(500)).color, Palette.muted)
    }

    func test_uptime_grows_into_hours() {
        XCTAssertEqual(formatUptime(0), "00:00")
        XCTAssertEqual(formatUptime(59), "00:59")
        XCTAssertEqual(formatUptime(61), "01:01")
        XCTAssertEqual(formatUptime(3723), "1:02:03")
        // Отрицательное время бывает при переводе часов назад — не показываем
        // пользователю «-1:59».
        XCTAssertEqual(formatUptime(-5), "00:00")
    }

    func test_vpn_mode_values_match_the_settings_file() {
        // Значения лежат в settings.json у пользователя: переименование
        // молча переключило бы всех обратно на прокси.
        XCTAssertEqual(VPNMode.proxy.rawValue, "proxy")
        XCTAssertEqual(VPNMode.tun.rawValue, "tun")
        XCTAssertEqual(VPNMode(rawValue: defaultSettings["vpn_mode"]!.stringValue!), .proxy)
    }
}
