import XCTest
@testable import SCVPNHelperKit

/// Демон здесь поднимается отдельным процессом — иначе сигнал ему не послать.
final class SignalTests: XCTestCase {

    func test_drops_tunnel_on_sigterm() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let daemon = try stand.serveSubprocess()
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        kill(daemon.processIdentifier, SIGTERM)
        XCTAssertTrue(stand.waitGone(timeout: 20), "туннель пережил SIGTERM демону")
    }

    func test_drops_tunnel_on_sighup() throws {
        // SIGHUP здесь не для красоты: демона запускают и руками, и закрытое
        // окно терминала не должно оставлять root-овый sing-box с маршрутами.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let daemon = try stand.serveSubprocess()
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        kill(daemon.processIdentifier, SIGHUP)
        XCTAssertTrue(stand.waitGone(timeout: 20), "туннель пережил SIGHUP демону")
    }

    func test_drops_tunnel_on_repeated_sigterm() throws {
        // Второй сигнал во время снятия не должен обрывать снятие на середине:
        // демон ушёл бы с кодом 0, а sing-box остался бы жив с маршрутами.
        let stand = try Stand(script: .stubborn)
        defer { stand.tearDown() }
        let daemon = try stand.serveSubprocess()
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        kill(daemon.processIdentifier, SIGTERM)
        Thread.sleep(forTimeInterval: 0.3)
        kill(daemon.processIdentifier, SIGTERM)
        kill(daemon.processIdentifier, SIGTERM)
        XCTAssertTrue(stand.waitGone(timeout: 25), "повторный сигнал оборвал снятие")
    }

    func test_refuses_second_instance() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        _ = try stand.serveSubprocess()
        let second = try stand.serveSubprocess(expectFailure: true)
        XCTAssertEqual(second.terminationStatus, 1)
    }

    func test_checks_lock_before_sweeping() throws {
        // Второй демон не должен успеть подмести sing-box первого:
        // killStaleSingbox бьёт по всей командной строке, не различая, чей это
        // процесс.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        _ = try stand.serveSubprocess()
        try stand.startTunnel()
        XCTAssertTrue(stand.waitUp(timeout: 10))
        let pids = stand.singboxPIDs()
        XCTAssertFalse(pids.isEmpty)

        _ = try? stand.serveSubprocess(expectFailure: true)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(stand.singboxPIDs(), pids, "второй демон снёс туннель первого")
    }

    func test_socket_is_removed_on_exit() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let daemon = try stand.serveSubprocess()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stand.socketPath))
        kill(daemon.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && FileManager.default.fileExists(atPath: stand.socketPath) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stand.socketPath))
    }

    func test_environment_overrides_are_ignored_under_root() {
        // Тестовая лазейка в продакшене — это дыра: через неё любой admin
        // подсунул бы демону свою папку бинарников. Под root переменные
        // окружения не читаются вовсе.
        let env = HelperEnv.fromEnvironment()
        if geteuid() == 0 {
            XCTAssertEqual(env.binDir.path, HelperEnv.production.binDir.path)
        } else {
            // Не от root проверяем обратное: без переменных окружение остаётся
            // продакшеновым, то есть лазейка не открывается сама по себе.
            XCTAssertEqual(env.socketPath, HelperEnv.production.socketPath)
        }
    }
}
