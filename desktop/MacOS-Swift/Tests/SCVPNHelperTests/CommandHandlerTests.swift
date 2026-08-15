import XCTest
@testable import SCVPNHelperKit

final class CommandHandlerTests: XCTestCase {

    private func json(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private func ctx() -> CommandContext {
        CommandContext(say: { _ in }, conn: nil)
    }

    func test_never_dies_on_deeply_nested_json() throws {
        // На глубоко вложенном JSON разборщик отдаёт ошибку, которая в Python
        // выходила наружу мимо всех веток — а наружу это обрыв соединения, то
        // есть снятие туннеля одной кривой строкой.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let deep = String(repeating: "[", count: 100_000)
        let reply = handleLine(deep, ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, false)
    }

    func test_never_dies_on_garbage() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        for line in ["не json", "", "[1,2,3]", "\"строка\"", "42", "{\"cmd\":", "null"] {
            let reply = handleLine(line, ctx(), stand.supervisor, stand.env)
            XCTAssertEqual(reply["ok"] as? Bool, false, line)
            XCTAssertNotNil(reply["error"], line)
        }
    }

    func test_unknown_command_is_refused_politely() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let reply = handleLine(json(["cmd": "самоуничтожиться"]), ctx(),
                               stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue(("\(reply["error"] ?? "")").contains("неизвестная команда"))
    }

    func test_rejects_oversized_split_apps_list() throws {
        // Потолки проверяются ДО валидации: 200 000 имён — это конфиг на
        // десяток мегабайт, который root молча запишет на диск.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let apps = (0..<300).map { "app\($0)" }
        let reply = handleLine(json(["cmd": "start", "socks_port": 10808,
                                     "split_apps": apps, "xray_path": stand.xrayPath]),
                               ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue(("\(reply["error"] ?? "")").contains("split_apps"))
    }

    func test_rejects_oversized_exclude_ips_list() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let ips = (0..<2000).map { "10.0.\($0 / 256).\($0 % 256)" }
        let reply = handleLine(json(["cmd": "start", "socks_port": 10808,
                                     "exclude_ips": ips, "xray_path": stand.xrayPath]),
                               ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, false)
    }

    func test_rejects_foreign_xray_path() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let reply = handleLine(json(["cmd": "start", "socks_port": 10808, "xray_path": "/bin/sh"]),
                               ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertFalse(stand.supervisor.isRunning)
    }

    func test_status_reports_singbox_presence() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        var reply = handleLine(json(["cmd": "status"]), ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["running"] as? Bool, false)
        XCTAssertEqual(reply["singbox"] as? Bool, true)

        try FileManager.default.removeItem(at: stand.env.singboxExe)
        reply = handleLine(json(["cmd": "status"]), ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["singbox"] as? Bool, false)
    }

    func test_stop_reply_tells_the_truth() throws {
        // sing-box имеет право пережить и SIGTERM, и SIGKILL. Ответить
        // «выключено», пока маршруты держатся, — это ровно та ложь про
        // состояние, от которой уходим.
        let stand = try Stand(script: .stubborn)
        _ = stand.withEnv { env in
            env.stopGrace = 0.05
            env.killGrace = 0
        }
        try stand.serveHere()
        defer { stand.tearDown() }

        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        let fd = try stand.connect(timeout: 15)
        let reply = try stand.ask(fd, ["cmd": "stop"])
        XCTAssertEqual(reply["running"] as? Bool, true)
        XCTAssertEqual(reply["ok"] as? Bool, false)
    }

    func test_stop_reply_is_true_when_the_tunnel_really_went_down() throws {
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        let fd = try stand.connect(timeout: 15)
        let reply = try stand.ask(fd, ["cmd": "stop"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["running"] as? Bool, false)
    }

    func test_remove_singbox_refuses_while_tunnel_is_up() throws {
        // unlink уберёт имя, но работающий процесс останется держать маршруты,
        // и снять его будет уже нечем: по командной строке его ищет
        // killStaleSingbox, а бинарника на диске не будет.
        let stand = try Stand(script: .normal).serveHere()
        defer { stand.tearDown() }
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        let fd = try stand.connect(timeout: 15)
        let reply = try stand.ask(fd, ["cmd": "remove_singbox"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stand.env.singboxExe.path))
    }

    func test_remove_singbox_removes_when_idle_and_is_idempotent() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        var reply = handleLine(json(["cmd": "remove_singbox"]), ctx(),
                               stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["removed"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stand.env.singboxExe.path))

        reply = handleLine(json(["cmd": "remove_singbox"]), ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["removed"] as? Bool, false)
    }

    func test_start_reply_is_exactly_what_the_client_expects() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let reply = handleLine(json(["cmd": "start", "socks_port": 10808,
                                     "xray_path": stand.xrayPath]),
                               ctx(), stand.supervisor, stand.env)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["running"] as? Bool, true)
        stand.supervisor.stop()
    }

    func test_every_reply_is_serializable() throws {
        // Ответ уезжает клиенту через JSONSerialization: несериализуемое
        // значение потерялось бы молча, а клиент ждал бы ответа до таймаута.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        for line in ["не json", json(["cmd": "status"]), json(["cmd": "нет такой"]),
                     json(["cmd": "start", "socks_port": true])] {
            let reply = handleLine(line, ctx(), stand.supervisor, stand.env)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(reply), line)
        }
    }
}
