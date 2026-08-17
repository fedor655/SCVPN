import XCTest
@testable import SCVPNCore
@testable import SCVPNHelperKit

/// Проверки клиента демона.
///
/// Живут в `SCVPNHelperTests`, а не в `SCVPNCoreTests`, как предлагал план:
/// стенд `Stand` — часть этого таргета, а поднимать его копию во втором значило
/// бы держать два стенда, расходящихся со временем. `Tun` при этом остаётся в
/// `SCVPNCore` — там ему и место, приложению он нужен, а демону нет.
final class HelperClientTests: XCTestCase {

    private let server = Server(proto: "vless", address: "127.0.0.1", port: 443, uuid: "u")

    /// Ядро Xray стенду нужно настоящее: путь уходит демону и проходит там
    /// `checkedXrayPath`, который требует файл с именем `xray`.
    private func tunFor(_ stand: Stand, onLog: @escaping (String) -> Void = { _ in },
                        onState: @escaping (Bool) -> Void = { _ in }) -> Tun {
        Paths.dataDir = stand.tmp
        try? FileManager.default.createDirectory(at: Paths.binDir, withIntermediateDirectories: true)
        let xray = Paths.binDir.appendingPathComponent("xray")
        FileManager.default.createFile(atPath: xray.path, contents: Data())
        chmod(xray.path, 0o755)
        return Tun(socketPath: stand.socketPath, onLog: onLog, onState: onState)
    }

    private var savedDataDir: URL!

    override func setUp() {
        super.setUp()
        savedDataDir = Paths.dataDir
    }

    override func tearDown() {
        Paths.dataDir = savedDataDir
        super.tearDown()
    }

    func test_tun_start_brings_the_tunnel_up() throws {
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let tun = tunFor(stand)
        try tun.start(server: server, socksPort: 10808)
        defer { tun.stop() }
        XCTAssertTrue(tun.isRunning)
        XCTAssertTrue(stand.waitUp(timeout: 10))
    }

    func test_tun_stop_reports_tunnel_that_survived_the_stop() throws {
        // sing-box имеет право пережить и SIGTERM, и SIGKILL. Тогда utun
        // поднят, маршруты держатся, а «Отключено» на экране — ровно та ложь
        // про состояние, ради ухода от которой правду и добывали.
        let stand = try Stand(script: .stubborn)
        _ = stand.withEnv { env in
            env.stopGrace = 0.05
            env.killGrace = 0
        }
        try stand.serveHere()
        defer { stand.tearDown() }

        let tun = tunFor(stand)
        try tun.start(server: server, socksPort: 10808)
        XCTAssertTrue(stand.waitUp(timeout: 10))

        XCTAssertFalse(tun.stop(), "stop соврал про снятый туннель")
        XCTAssertTrue(tun.isRunning)
    }

    func test_tun_stop_reports_success_when_the_tunnel_really_went_down() throws {
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let tun = tunFor(stand)
        try tun.start(server: server, socksPort: 10808)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        XCTAssertTrue(tun.stop())
        XCTAssertFalse(tun.isRunning)
        XCTAssertTrue(stand.waitGone(timeout: 10))
    }

    func test_stop_reply_is_not_eaten_by_the_log_reader() throws {
        // Два читателя на одном сокете отдавали бы строки кому попало, и ответ
        // на stop терялся бы, подвешивая stop() до таймаута. Здесь проверяем
        // именно это: ответ приходит быстро, а не по истечении 12 секунд.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let tun = tunFor(stand)
        try tun.start(server: server, socksPort: 10808)
        XCTAssertTrue(stand.waitUp(timeout: 10))

        let started = Date()
        XCTAssertTrue(tun.stop())
        XCTAssertLessThan(Date().timeIntervalSince(started), stopReplyTimeoutSec - 2,
                          "ответ на stop ждали до таймаута — его съел поток логов")
    }

    func test_tun_reports_disconnect_when_the_daemon_goes_away() throws {
        // Клиентская половина главного свойства: соединение оборвалось без
        // команды stop — значит туннеля больше нет, и экран обязан это узнать.
        //
        // Python проверял симметричный случай — убивал клиентский ПРОЦЕСС и
        // смотрел, снял ли демон туннель. Здесь это не воспроизвести в том же
        // процессе: поток-читатель держит Tun живым, пока сокет открыт, а
        // сокет закроется только вместе с потоком. Со стороны демона тот же
        // сценарий закрыт проверкой test_daemon_drops_tunnel_when_connection_closes,
        // а живьём — ручной проверкой Задачи 2.14 (kill -9 приложения, PID
        // демона не сменился, sing-box снят).
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let daemon = try stand.serveSubprocess()

        let states = Collector()
        let tun = tunFor(stand, onState: { states.add($0 ? "up" : "down") })
        try tun.start(server: server, socksPort: 10808)
        XCTAssertTrue(stand.waitUp(timeout: 10))

        kill(daemon.processIdentifier, SIGTERM)
        XCTAssertTrue(states.wait(for: "down", timeout: 20),
                      "клиент не заметил обрыва соединения: \(states.all)")
        XCTAssertFalse(tun.isRunning)
        XCTAssertTrue(stand.waitGone(timeout: 20))
    }

    func test_disconnect_does_not_report_idle_when_tunnel_survived() throws {
        let stand = try Stand(script: .stubborn)
        _ = stand.withEnv { env in
            env.stopGrace = 0.05
            env.killGrace = 0
        }
        try stand.serveHere()
        defer { stand.tearDown() }

        let states = Collector()
        let tun = tunFor(stand, onState: { states.add($0 ? "up" : "down") })
        try tun.start(server: server, socksPort: 10808)
        XCTAssertTrue(stand.waitUp(timeout: 10))

        XCTAssertFalse(tun.stop())
        // Ни одного «отключено» после неудачной остановки: экран не должен
        // говорить «Отключено», пока маршруты держатся.
        XCTAssertFalse(states.contains("down"), "\(states.all)")
    }

    func test_tun_reports_disconnect_when_singbox_dies_on_its_own() throws {
        // Демон снял sing-box сам, а соединение при этом НЕ рвёт: приложение
        // живо, просто без туннеля. Без разбора этой строки Tun продолжал бы
        // считать себя подключённым.
        let stand = try Stand(script: .crashing).serveHere()
        defer { stand.tearDown() }
        let states = Collector()
        let tun = tunFor(stand, onState: { states.add($0 ? "up" : "down") })
        try tun.start(server: server, socksPort: 10808)
        defer { tun.stop() }

        XCTAssertTrue(states.wait(for: "down", timeout: 10),
                      "не узнали, что sing-box завершился сам: \(states.all)")
        XCTAssertFalse(tun.isRunning)
    }

    func test_second_start_closes_the_previous_connection() throws {
        // Прошлая сессия могла не закрыть своё соединение сама: onState(false)
        // уже пришёл (sing-box умер сам), а стоп не позвали. Без явного
        // закрытия второй start завёл бы ещё один сокет и поток поверх висящего.
        let stand = try Stand(script: .crashing).serveHere()
        defer { stand.tearDown() }
        let states = Collector()
        let tun = tunFor(stand, onState: { states.add($0 ? "up" : "down") })

        try tun.start(server: server, socksPort: 10808)
        XCTAssertTrue(states.wait(for: "down", timeout: 10))

        XCTAssertNoThrow(try tun.start(server: server, socksPort: 10808))
        defer { tun.stop() }
        XCTAssertTrue(tun.isRunning)
    }

    func test_start_closes_connection_when_the_daemon_refuses() throws {
        // Отказ приходит уже ПОСЛЕ того, как демон мог поднять туннель. Не
        // закрой мы соединение, туннель остался бы поднятым до тех пор, пока
        // до сокета не доберётся сборщик, то есть непредсказуемо.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        Paths.dataDir = stand.tmp
        // Ядра нет — checkedXrayPath на стороне демона откажет.
        let tun = Tun(socketPath: stand.socketPath)
        XCTAssertThrowsError(try tun.start(server: server, socksPort: 10808))
        XCTAssertFalse(tun.isRunning)
        XCTAssertTrue(stand.waitGone(timeout: 10))
    }

    func test_stop_without_a_start_is_honest() throws {
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        // Нечего снимать — значит снято.
        XCTAssertTrue(Tun(socketPath: stand.socketPath).stop())
    }

    func test_connection_to_a_missing_daemon_explains_itself() {
        XCTAssertThrowsError(try HelperConnection(socketPath: "/tmp/нет-такого.sock",
                                                  onLog: { _ in })) { e in
            XCTAssertTrue("\(e)".contains("Системный компонент не отвечает"), "\(e)")
        }
    }

    func test_a_short_lived_connection_does_not_drop_the_tunnel() throws {
        // install_singbox и подобные открывают отдельное соединение на один
        // запрос и закрывают его же. Обрыв такого соединения не должен ронять
        // чужой активный туннель.
        //
        // Команда здесь status, а не install_singbox: вторая ушла бы в сеть и
        // скачала настоящий sing-box — десять мегабайт и полторы минуты на
        // проверку свойства, которое к загрузке отношения не имеет.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let tun = tunFor(stand)
        try tun.start(server: server, socksPort: 10808)
        defer { tun.stop() }
        XCTAssertTrue(stand.waitUp(timeout: 10))

        let side = try HelperConnection(socketPath: stand.socketPath, onLog: { _ in })
        let reply = try side.request(["cmd": "status"], timeout: 10)
        XCTAssertEqual(reply["running"] as? Bool, true)
        side.close()

        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(stand.singboxPIDs().isEmpty, "разовое соединение снесло туннель")
        XCTAssertTrue(tun.isRunning)
    }

    func test_resolve_ips_returns_a_literal_untouched() {
        XCTAssertEqual(resolveIPs("1.2.3.4"), ["1.2.3.4"])
        XCTAssertEqual(resolveIPs("2001:db8::1"), ["2001:db8::1"])
        XCTAssertEqual(resolveIPs("не.существует.вообще.invalid"), [])
        // Резолв берёт обе версии, а localhost в /etc/hosts обычно и v4, и v6 —
        // поэтому жёсткого равенства тут быть не может.
        let local = Set(resolveIPs("localhost"))
        XCTAssertTrue(local.contains("127.0.0.1"), "не нашёл 127.0.0.1: \(local)")
        XCTAssertTrue(local.isSubset(of: ["127.0.0.1", "::1"]), "лишние адреса: \(local)")
    }
}
