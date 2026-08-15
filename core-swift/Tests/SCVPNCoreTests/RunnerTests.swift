#if os(macOS)
import XCTest
@testable import SCVPNCore

final class RunnerTests: StorageIsolatedTestCase {

    func test_find_free_port_skips_a_busy_one() throws {
        let taken = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(taken, 0)
        defer { close(taken) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(20000).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(taken, $0, size) == 0 }
        }
        try XCTSkipUnless(bound, "порт 20000 занят кем-то ещё — проверять нечего")
        XCTAssertNotEqual(findFreePort(preferred: 20000), 20000)
    }

    func test_find_free_port_returns_the_preferred_one_when_it_is_free() {
        let port = findFreePort(preferred: 34567)
        XCTAssertGreaterThanOrEqual(port, 34567)
    }

    func test_tcp_ping_returns_nil_for_a_closed_port() {
        // Порт 1 на loopback не слушает никто, и ответ обязан прийти сразу,
        // а не через системный таймаут в минуту.
        let start = Date()
        XCTAssertNil(tcpPing(host: "127.0.0.1", port: 1, timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func test_tcp_ping_returns_nil_for_an_unresolvable_host() {
        XCTAssertNil(tcpPing(host: "не.существует.вообще.invalid", port: 443, timeout: 2))
    }

    func test_tcp_ping_measures_a_listening_port() throws {
        let srv = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(srv, 0)
        defer { close(srv) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(srv, $0, size) }
        }
        listen(srv, 1)
        var out = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &out) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(srv, $0, &size) }
        }
        let port = Int(UInt16(bigEndian: out.sin_port))
        let ms = try XCTUnwrap(tcpPing(host: "127.0.0.1", port: port, timeout: 2))
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertLessThan(ms, 2000)
    }

    func test_runner_refuses_to_start_without_a_core() throws {
        try withTempDataDir { _ in
            // Внятный отказ, а не падение: на чистой машине ядра ещё нет, и
            // пользователь должен прочитать, что делать.
            XCTAssertThrowsError(try XrayRunner().start(["log": ["loglevel": "error"]])) { e in
                XCTAssertTrue("\(e)".contains("ядро Xray"), "\(e)")
            }
        }
    }

    func test_cleanup_stray_ignores_a_pid_that_is_not_ours() throws {
        // Номера PID переиспользуются: слепой kill по записи из файла рано или
        // поздно попал бы в чужой процесс.
        try withTempDataDir { _ in
            Paths.ensureDirs()
            try Data("1".utf8).write(to: Paths.xrayPIDFile)   // launchd, точно не наш
            XCTAssertFalse(XrayRunner.cleanupStray())
            XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.xrayPIDFile.path))
        }
    }

    func test_cleanup_stray_is_silent_without_a_pid_file() {
        withTempDataDir { _ in
            XCTAssertFalse(XrayRunner.cleanupStray())
        }
    }

    func test_cleanup_stray_ignores_garbage_in_the_pid_file() throws {
        try withTempDataDir { _ in
            Paths.ensureDirs()
            try Data("не число".utf8).write(to: Paths.xrayPIDFile)
            XCTAssertFalse(XrayRunner.cleanupStray())
        }
    }
}

final class HWIDTests: StorageIsolatedTestCase {

    func test_hwid_is_stable_across_calls() {
        withTempDataDir { _ in
            XCTAssertEqual(deviceID(), deviceID())
        }
    }

    func test_hwid_is_persisted_in_settings() {
        withTempDataDir { _ in
            let id = deviceID()
            // Значение обязано лечь в settings.json: пересчёт после
            // переустановки системы занял бы новый слот в лимите устройств.
            XCTAssertEqual(loadSettings()["hwid"], .string(id))
        }
    }

    func test_hwid_format_is_a_uuid() {
        withTempDataDir { _ in
            XCTAssertNotNil(UUID(uuidString: deviceID()))
        }
    }

    func test_saved_hwid_wins_over_a_freshly_computed_one() {
        withTempDataDir { _ in
            var s = loadSettings()
            s["hwid"] = .string("11111111-2222-3333-4444-555555555555")
            saveSettings(s)
            XCTAssertEqual(deviceID(), "11111111-2222-3333-4444-555555555555")
        }
    }

    func test_machine_source_is_not_empty() {
        // Пустой источник дал бы всем пользователям один и тот же HWID.
        XCTAssertFalse(machineSource().isEmpty)
        XCTAssertNotEqual(machineSource(), "mac-000000000000")
    }

    func test_device_headers_are_exactly_the_four_python_sent() {
        withTempDataDir { _ in
            let h = deviceHeaders()
            XCTAssertEqual(Set(h.keys),
                           ["x-hwid", "x-device-os", "x-ver-os", "x-device-model"])
            XCTAssertEqual(h["x-device-os"], "Darwin")
            XCTAssertFalse(h["x-ver-os"]?.isEmpty ?? true)
        }
    }
}

final class FingerprintTests: XCTestCase {

    func test_explicit_override_skips_probing() {
        XCTAssertEqual(candidateFingerprints(Server(), override: "safari"), ["safari"])
    }

    func test_server_fingerprint_goes_first_but_randomized_does_not() {
        var s = Server()
        s.fingerprint = "randomized"
        // randomized от панели означает «панель не знает», а не «панель просит
        // случайный»: ставить его первым значило бы подбирать нестабильное.
        XCTAssertEqual(candidateFingerprints(s, override: "auto").first, "firefox")

        s.fingerprint = "safari"
        XCTAssertEqual(candidateFingerprints(s, override: "auto").first, "safari")
    }

    func test_fallback_order_is_frozen() {
        // Сперва те, что не шлют пост-квантовых кривых: chrome в свежих
        // сборках Xray шлёт X25519MLKEM768, и часть серверов на ней виснет.
        XCTAssertEqual(candidateFingerprints(Server(), override: "auto"),
                       ["firefox", "chrome", "safari", "edge", "ios", "randomized"])
    }

    func test_server_fingerprint_is_not_duplicated_in_the_list() {
        var s = Server()
        s.fingerprint = "Chrome"          // регистр из подписки бывает любой
        let c = candidateFingerprints(s, override: "auto")
        XCTAssertEqual(c.first, "chrome")
        XCTAssertEqual(c.filter { $0 == "chrome" }.count, 1)
    }

    func test_empty_override_still_probes() {
        XCTAssertGreaterThan(candidateFingerprints(Server(), override: "").count, 1)
    }
}
#endif
