import XCTest
@testable import SCVPNCore
@testable import SCVPNHelperKit

/// Главное свойство всего проекта: обрыв соединения снимает туннель, но только
/// свой.
final class DeadMansSwitchTests: XCTestCase {

    func test_daemon_drops_tunnel_when_connection_closes() throws {
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let fd = try stand.connect(timeout: 15)
        _ = try stand.ask(fd, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
        XCTAssertTrue(stand.waitUp(timeout: 10))
        close(fd)
        XCTAssertTrue(stand.waitGone(timeout: 15), "туннель пережил обрыв клиента")
    }

    func test_daemon_leaves_foreign_tunnel_alone_on_disconnect() throws {
        // install_singbox открывает отдельное соединение на один запрос и
        // закрывает его же — такое соединение не должно ронять чужой активный
        // туннель одним своим обрывом.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let owner = try stand.connect(timeout: 15)
        _ = try stand.ask(owner, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
        XCTAssertTrue(stand.waitUp(timeout: 10))

        let bystander = try stand.connect(timeout: 15)
        _ = try stand.ask(bystander, ["cmd": "status"])
        close(bystander)

        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(stand.singboxPIDs().isEmpty, "посторонний обрыв снёс чужой туннель")
    }

    func test_daemon_drops_ownerless_tunnel_on_any_disconnect() throws {
        // owner == nil не должен означать «висит навсегда»: туннель без
        // хозяина обязан снять первый же отключившийся. Отказ в безопасную
        // сторону — на случай дефекта, о котором мы ещё не знаем.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }

        // Поднимаем туннель мимо сокета, чтобы владельца не было вовсе.
        let params = try validate(["socks_port": 10808])
        try stand.supervisor.start(params, xrayPath: stand.xrayPath,
                                   onLog: { _ in }, owner: nil)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        XCTAssertNil(stand.supervisor.owner)

        let bystander = try stand.connect(timeout: 15)
        _ = try stand.ask(bystander, ["cmd": "status"])
        close(bystander)
        XCTAssertTrue(stand.waitGone(timeout: 15), "бесхозный туннель остался висеть")
    }

    func test_refuses_line_longer_than_the_ceiling() throws {
        // Строка без перевода строки не должна расти в памяти root-процесса
        // бесконечно.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let fd = try stand.connect(timeout: 15)
        let huge = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) + 4096)
        XCTAssertTrue(writeAll(fd, huge))
        let reply = try stand.reply(fd)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue(("\(reply["error"] ?? "")").contains("длиннее"))
    }

    func test_second_connection_can_take_over_after_the_first_one_left() throws {
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        let first = try stand.connect(timeout: 15)
        _ = try stand.ask(first, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])
        XCTAssertTrue(stand.waitUp(timeout: 10))
        close(first)
        XCTAssertTrue(stand.waitGone(timeout: 15))

        let second = try stand.connect(timeout: 15)
        let reply = try stand.ask(second, ["cmd": "start", "socks_port": 10808,
                                           "xray_path": stand.xrayPath])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        close(second)
        XCTAssertTrue(stand.waitGone(timeout: 15))
    }

    func test_singbox_logs_reach_the_client_over_the_same_connection() throws {
        let stand = try Stand(script: .crashing).serveHere()
        defer { stand.tearDown() }
        let fd = try stand.connect(timeout: 15)
        _ = try stand.ask(fd, ["cmd": "start", "socks_port": 10808, "xray_path": stand.xrayPath])

        // Демон снял sing-box сам, а соединение при этом НЕ рвёт: приложение
        // живо, просто без туннеля. Клиент узнаёт об этом строкой лога.
        var sawExit = false
        var buf = [UInt8](repeating: 0, count: 65536)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let deadline = Date().addingTimeInterval(10)
        var pending = Data()
        while Date() < deadline && !sawExit {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            while let idx = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<idx]
                pending.removeSubrange(pending.startIndex...idx)
                if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let text = obj["log"] as? String, text.contains("завершился") {
                    sawExit = true
                }
            }
        }
        XCTAssertTrue(sawExit, "клиент не узнал, что sing-box сам завершился")
    }
}
