import XCTest
@testable import SCVPNCore

/// Поддельная сеть: набор сервисов и их состояние в памяти.
///
/// Настоящий `networksetup` правит настройки машины, на которой идёт прогон.
/// Проверять на нём каждое правило значило бы дёргать сеть пользователя два
/// десятка раз за прогон — при том, что рядом живут другие VPN-клиенты с теми
/// же `127.0.0.1`. Живьём остаётся один круг откат-восстановление, и тот с
/// предварительной проверкой, что чужого прокси на машине нет.
final class FakeNetworksetup {
    struct Proxy { var enabled = "No"; var server = ""; var port = "0" }
    struct Service { var web = Proxy(); var secure = Proxy(); var bypass: [String] = [] }

    var services: [String: Service]
    /// Сервисы, у которых нет реального устройства: VPN-конфиги и выключенные.
    var virtualServices: [String] = []
    var disabledServices: [String] = []
    private(set) var calls: [[String]] = []

    init(services: [String: Service] = ["Wi-Fi": Service()]) {
        self.services = services
    }

    func install() {
        SystemProxy.runNetworksetup = { [weak self] args in self?.run(args) ?? "" }
    }

    func run(_ args: [String]) -> String {
        calls.append(args)
        guard let cmd = args.first else { return "" }
        switch cmd {
        case "-listnetworkserviceorder":
            var out = ""
            var i = 1
            for name in services.keys.sorted() {
                out += "(\(i)) \(name)\n(Hardware Port: \(name), Device: en\(i))\n"
                i += 1
            }
            for name in virtualServices {
                out += "(\(i)) \(name)\n"          // второй строки нет вовсе
                i += 1
            }
            for name in disabledServices {
                out += "(*) \(name)\n(Hardware Port: \(name), Device: en\(i))\n"
                i += 1
            }
            return out

        case "-getwebproxy", "-getsecurewebproxy":
            guard let s = services[args[1]] else { return "" }
            let p = cmd == "-getwebproxy" ? s.web : s.secure
            return "Enabled: \(p.enabled)\nServer: \(p.server)\nPort: \(p.port)\n"

        case "-getproxybypassdomains":
            guard let s = services[args[1]], !s.bypass.isEmpty else {
                return "There aren't any bypass domains set on \(args[1]).\n"
            }
            return s.bypass.joined(separator: "\n") + "\n"

        case "-setwebproxy", "-setsecurewebproxy":
            guard var s = services[args[1]] else { return "" }
            var p = Proxy(enabled: "Yes", server: args[2], port: args[3])
            // -set*proxy сам взводит Enabled даже при пустом Server — ровно то
            // поведение настоящего networksetup, ради которого следом идёт
            // отдельная команда -set*proxystate.
            p.enabled = "Yes"
            if cmd == "-setwebproxy" { s.web = p } else { s.secure = p }
            services[args[1]] = s
            return ""

        case "-setwebproxystate", "-setsecurewebproxystate":
            guard var s = services[args[1]] else { return "" }
            let on = args[2] == "on" ? "Yes" : "No"
            if cmd == "-setwebproxystate" { s.web.enabled = on } else { s.secure.enabled = on }
            services[args[1]] = s
            return ""

        case "-setproxybypassdomains":
            guard var s = services[args[1]] else { return "" }
            let list = Array(args.dropFirst(2))
            s.bypass = list == ["Empty"] ? [] : list
            services[args[1]] = s
            return ""

        default:
            return ""
        }
    }
}

final class SystemProxyTests: StorageIsolatedTestCase {

    private var net: FakeNetworksetup!
    private var savedRunner: (([String]) -> String)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedRunner = SystemProxy.runNetworksetup
        net = FakeNetworksetup()
        net.install()
    }

    override func tearDownWithError() throws {
        SystemProxy.runNetworksetup = savedRunner
        try super.tearDownWithError()
    }

    // ---- разбор вывода networksetup ----

    func test_hardware_services_skips_vpn_configs_and_disabled_ones() {
        net.services = ["Wi-Fi": .init(), "Ethernet": .init()]
        net.virtualServices = ["Мой VPN"]      // второй строки нет
        net.disabledServices = ["Thunderbolt Bridge"]   // номер заменён звёздочкой
        XCTAssertEqual(SystemProxy.hardwareServices().sorted(), ["Ethernet", "Wi-Fi"])
    }

    func test_empty_bypass_phrase_is_not_mistaken_for_a_domain() {
        // Пустой список networksetup описывает человеческой фразой с пробелами,
        // а домены пробелов не содержат — этим и отличаем.
        net.services = ["Wi-Fi": .init()]
        XCTAssertEqual(SystemProxy.readBypass("Wi-Fi"), [])
    }

    func test_bypass_list_is_read_back() {
        net.services = ["Wi-Fi": .init(web: .init(), secure: .init(),
                                       bypass: ["localhost", "*.local"])]
        XCTAssertEqual(SystemProxy.readBypass("Wi-Fi"), ["localhost", "*.local"])
    }

    // ---- снимок ----

    func test_enable_without_services_refuses_instead_of_pretending() {
        net.services = [:]
        XCTAssertThrowsError(try SystemProxy.enable(host: "127.0.0.1", port: 10809))
    }

    func test_snapshot_round_trip_restores_state() throws {
        // Прежнее состояние: чужой прокси включён на другом порту.
        net.services = ["Wi-Fi": .init(web: .init(enabled: "Yes", server: "127.0.0.1", port: "7890"),
                                       secure: .init(enabled: "No", server: "", port: "0"),
                                       bypass: ["*.local"])]
        let before = net.services

        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        XCTAssertEqual(net.services["Wi-Fi"]?.web.port, "10809")

        SystemProxy.disable()
        XCTAssertEqual(net.services["Wi-Fi"]?.web.server, before["Wi-Fi"]?.web.server)
        XCTAssertEqual(net.services["Wi-Fi"]?.web.port, before["Wi-Fi"]?.web.port)
        XCTAssertEqual(net.services["Wi-Fi"]?.web.enabled, "Yes")
        XCTAssertEqual(net.services["Wi-Fi"]?.secure.enabled, "No")
        XCTAssertEqual(net.services["Wi-Fi"]?.bypass, ["*.local"])
    }

    func test_disable_restores_the_off_state_explicitly() throws {
        // -set*proxy сам взводит Enabled даже при пустом Server. Без отдельной
        // команды -set*proxystate следом Server и Port от нашего enable() тихо
        // остались бы висеть включёнными.
        net.services = ["Wi-Fi": .init()]      // было выключено и пусто
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        SystemProxy.disable()
        XCTAssertEqual(net.services["Wi-Fi"]?.web.enabled, "No")
        XCTAssertEqual(net.services["Wi-Fi"]?.secure.enabled, "No")
    }

    func test_disable_leaves_a_foreign_proxy_alone() {
        // Снимка нет — значит этот прокси ставили не мы. Один запуск SCVPN
        // вхолостую не должен стирать настройку чужого клиента.
        net.services = ["Wi-Fi": .init(web: .init(enabled: "Yes", server: "127.0.0.1", port: "7890"))]
        let before = net.services
        SystemProxy.disable()
        XCTAssertEqual(net.services["Wi-Fi"]?.web.server, before["Wi-Fi"]?.web.server)
        XCTAssertEqual(net.services["Wi-Fi"]?.web.port, "7890")
        XCTAssertEqual(net.services["Wi-Fi"]?.web.enabled, "Yes")
    }

    func test_repeated_enable_does_not_remember_our_own_settings_as_before() throws {
        net.services = ["Wi-Fi": .init(web: .init(enabled: "Yes", server: "127.0.0.1", port: "7890"))]
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        try SystemProxy.enable(host: "127.0.0.1", port: 10999)   // порт сменился
        SystemProxy.disable()
        // Вернуться должно к чужому 7890, а не к нашему первому 10809.
        XCTAssertEqual(net.services["Wi-Fi"]?.web.port, "7890")
    }

    func test_enable_refreshes_our_own_address_in_the_snapshot() throws {
        // Порт выбирается при каждом подключении заново, и по устаревшему
        // потом не опознать собственный прокси.
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        try SystemProxy.enable(host: "127.0.0.1", port: 10999)
        XCTAssertEqual(SystemProxy.loadSnapshot()?.proxy?.port, 10999)
        XCTAssertTrue(SystemProxy.systemProxyIsOurs())
    }

    func test_disable_ignores_a_service_that_was_not_in_the_snapshot() throws {
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        // Кабель воткнули уже после включения: этого сервиса в снимке нет,
        // возвращать его «как было» нам не к чему и не по праву.
        net.services["Ethernet"] = .init(web: .init(enabled: "Yes", server: "10.0.0.1", port: "3128"))
        SystemProxy.disable()
        XCTAssertEqual(net.services["Ethernet"]?.web.server, "10.0.0.1")
        XCTAssertEqual(net.services["Ethernet"]?.web.port, "3128")
    }

    // ---- «наш ли это прокси» ----

    func test_is_ours_is_false_without_a_snapshot() {
        net.services = ["Wi-Fi": .init(web: .init(enabled: "Yes", server: "127.0.0.1", port: "10809"))]
        XCTAssertFalse(SystemProxy.systemProxyIsOurs())
    }

    func test_is_enabled_wants_our_own_port_not_just_localhost() throws {
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        // Поверх нашего встал чужой клиент на том же хосте, но своём порту.
        net.services["Wi-Fi"]?.web = .init(enabled: "Yes", server: "127.0.0.1", port: "7890")
        XCTAssertFalse(SystemProxy.systemProxyIsOurs())
    }

    func test_is_enabled_recognizes_old_snapshot_format() throws {
        // Снимок прежнего формата: сервисы прямо в корне, блока proxy нет.
        // Понять его надо — он хранит НАСТОЯЩЕЕ прежнее состояние сети.
        Paths.ensureDirs()
        try Data(#"{"Wi-Fi": {"web": {"Enabled": "No"}}}"#.utf8)
            .write(to: SystemProxy.snapshotFile)
        net.services["Wi-Fi"]?.web = .init(enabled: "Yes", server: "127.0.0.1", port: "7890")
        // Старый формат сверяет только хост: порта он не знал.
        XCTAssertTrue(SystemProxy.systemProxyIsOurs())
    }

    func test_old_snapshot_format_is_still_restorable() throws {
        Paths.ensureDirs()
        try Data(#"{"Wi-Fi": {"web": {"Enabled": "Yes", "Server": "10.0.0.9", "Port": "3128"}, "bypass": ["*.local"]}}"#.utf8)
            .write(to: SystemProxy.snapshotFile)
        net.services["Wi-Fi"]?.web = .init(enabled: "Yes", server: "127.0.0.1", port: "10809")
        SystemProxy.disable()
        XCTAssertEqual(net.services["Wi-Fi"]?.web.server, "10.0.0.9")
        XCTAssertEqual(net.services["Wi-Fi"]?.web.port, "3128")
        XCTAssertEqual(net.services["Wi-Fi"]?.bypass, ["*.local"])
    }

    func test_snapshot_is_removed_after_disable() throws {
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SystemProxy.snapshotFile.path))
        SystemProxy.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: SystemProxy.snapshotFile.path))
    }

    func test_socks_is_never_touched() throws {
        // Наружу мы отдаём только HTTP-порт Xray. Записать его в
        // -setsocksfirewallproxy значило бы отправить SOCKS-клиентов на
        // HTTP-инбаунд.
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        SystemProxy.disable()
        XCTAssertFalse(net.calls.contains { $0.first?.contains("socks") == true })
    }

    func test_bypass_covers_local_networks() throws {
        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        let bypass = net.services["Wi-Fi"]?.bypass ?? []
        for entry in ["localhost", "127.0.0.1", "192.168.0.0/16", "*.local"] {
            XCTAssertTrue(bypass.contains(entry), entry)
        }
    }
}
