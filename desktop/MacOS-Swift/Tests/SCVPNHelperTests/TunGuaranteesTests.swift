import XCTest
@testable import SCVPNCore
@testable import SCVPNHelperKit

/// Свойства, найденные сплошным чтением `test_native.py` (Задача 0.9) и не
/// закрытые остальными проверками переноса.
final class TunGuaranteesTests: XCTestCase {

    private let server = Server(proto: "vless", address: "127.0.0.1", port: 443, uuid: "u")
    private var savedDataDir: URL!

    override func setUp() {
        super.setUp()
        savedDataDir = Paths.dataDir
    }

    override func tearDown() {
        Paths.dataDir = savedDataDir
        super.tearDown()
    }

    private func tunFor(_ stand: Stand, onState: @escaping (Bool) -> Void = { _ in }) -> Tun {
        Paths.dataDir = stand.tmp
        try? FileManager.default.createDirectory(at: Paths.binDir, withIntermediateDirectories: true)
        let xray = Paths.binDir.appendingPathComponent("xray")
        FileManager.default.createFile(atPath: xray.path, contents: Data())
        chmod(xray.path, 0o755)
        return Tun(socketPath: stand.socketPath, onLog: { _ in }, onState: onState)
    }

    // ------------------------------------------------------------------
    // Два независимых способа снять туннель
    // ------------------------------------------------------------------

    func test_stop_command_alone_drops_the_tunnel() throws {
        // Первая из двух гарантий: демон снимает туннель по самой команде,
        // без обрыва соединения. Соединение оставляем открытым намеренно —
        // иначе непонятно, что именно сработало.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        let fd = try stand.connect(timeout: 15)
        _ = try stand.ask(fd, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
        XCTAssertTrue(stand.waitUp(timeout: 10))

        let reply = try stand.ask(fd, ["cmd": "stop"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertTrue(stand.waitGone(timeout: 10), "команда stop туннель не сняла")
        // Соединение всё ещё живо — значит сняла именно команда.
        let after = try stand.ask(fd, ["cmd": "status"])
        XCTAssertEqual(after["running"] as? Bool, false)
    }

    func test_closing_the_connection_alone_drops_the_tunnel() throws {
        // Вторая гарантия: даже если команда stop не дошла вовсе, обрыв
        // соединения снимает туннель сам. Две независимые гарантии обязаны
        // работать поодиночке — иначе «починка» одной тихо ломает другую.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        let fd = try stand.connect(timeout: 15)
        _ = try stand.ask(fd, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
        XCTAssertTrue(stand.waitUp(timeout: 10))

        close(fd)   // ни команды, ни прощания
        XCTAssertTrue(stand.waitGone(timeout: 15), "обрыв соединения туннель не снял")
    }

    // ------------------------------------------------------------------
    // Пробуждение читателя
    // ------------------------------------------------------------------

    func test_closing_wakes_a_reader_blocked_in_stream() throws {
        // shutdown обязан идти раньше close: иначе поток, заблокированный в
        // чтении, не гарантированно проснётся сразу. Проверяем следствие, а не
        // порядок вызовов — следствие и есть то, ради чего порядок выбран.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        let conn = try HelperConnection(socketPath: stand.socketPath, onLog: { _ in })
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            conn.stream { _ in }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        Thread.sleep(forTimeInterval: 0.3)   // дать потоку встать в чтение

        conn.close()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success,
                       "читатель не проснулся после закрытия соединения")
    }

    // ------------------------------------------------------------------
    // Настройка стека доезжает до конфига
    // ------------------------------------------------------------------

    func test_tun_stack_setting_reaches_the_singbox_config() throws {
        // Значение обязано долететь от настроек через демона до JSON на диске,
        // а не потеряться по дороге.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        let tun = tunFor(stand)
        try tun.start(server: server, socksPort: 10808, stack: .mixed)
        defer { tun.stop() }
        XCTAssertTrue(stand.waitUp(timeout: 10))

        let raw = try Data(contentsOf: stand.env.configPath)
        let cfg = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let tunInbound = (cfg["inbounds"] as! [[String: Any]])[0]
        XCTAssertEqual(tunInbound["stack"] as? String, "mixed")
    }

    func test_default_stack_is_gvisor_and_comes_from_real_settings() throws {
        // Половина, которую предыдущая проверка не ловит: удали `tun_stack` из
        // умолчаний совсем — она этого не заметит, потому что значение туда
        // передаётся руками. Здесь настройки читаются настоящие, без файла на
        // диске, то есть единственный источник — defaultSettings.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        Paths.dataDir = stand.tmp
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.settingsFile.path))
        let stackName = loadSettings()["tun_stack"]?.stringValue
        XCTAssertEqual(stackName, "gvisor", "умолчание tun_stack пропало из настроек")

        let tun = tunFor(stand)
        try tun.start(server: server, socksPort: 10808,
                      stack: Stack(rawValue: stackName ?? "") ?? .system)
        defer { tun.stop() }
        XCTAssertTrue(stand.waitUp(timeout: 10))

        let raw = try Data(contentsOf: stand.env.configPath)
        let cfg = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(((cfg["inbounds"] as! [[String: Any]])[0])["stack"] as? String, "gvisor")
    }

    // ------------------------------------------------------------------
    // Крах обслуживания
    // ------------------------------------------------------------------

    func test_a_broken_foreign_connection_leaves_the_tunnel_alone() throws {
        // Обслуживание может свалиться не только на чтении. Если такое
        // случилось на ЧУЖОМ соединении — том, что ничего не поднимало, — по
        // владельцу туннеля это трогать не должно.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        let owner = try stand.connect(timeout: 15)
        _ = try stand.ask(owner, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
        XCTAssertTrue(stand.waitUp(timeout: 10))

        // Постороннее соединение обрывается на середине запроса: половина
        // строки без перевода, затем закрытие.
        let stranger = try stand.connect(timeout: 15)
        _ = writeAllClient(stranger, Data("{\"cmd\": \"sta".utf8))
        close(stranger)

        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(stand.singboxPIDs().isEmpty,
                       "крах на чужом соединении снёс чужой туннель")
    }

    func test_a_broken_owning_connection_drops_the_tunnel() throws {
        // Симметрично предыдущей: крах на СВОЁМ соединении обязан снять
        // туннель, как и любой другой обрыв владеющего. Без этой пары легко
        // «починить» одну сторону так, что перестанет работать другая.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        let owner = try stand.connect(timeout: 15)
        _ = try stand.ask(owner, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
        XCTAssertTrue(stand.waitUp(timeout: 10))

        _ = writeAllClient(owner, Data("{\"cmd\": \"sta".utf8))
        close(owner)
        XCTAssertTrue(stand.waitGone(timeout: 15), "крах владеющего соединения туннель не снял")
    }
}
