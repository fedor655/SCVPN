#if os(iOS)
import XCTest
@testable import SCVPNCore

/// Порядок подъёма туннеля и откат на каждом шаге.
///
/// Живьём это не проверить: NetworkExtension не работает ни в симуляторе, ни в
/// проверках. Поэтому шаги — замыкания, а здесь стоят подделки.
final class TunnelBringUpTests: XCTestCase {

    /// Журнал вызовов: по нему видно и порядок, и что откатилось.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var steps: [String] = []
        func add(_ s: String) { lock.lock(); steps.append(s); lock.unlock() }
    }

    private struct Boom: Error {}

    private func bringUp(_ log: Log,
                         coreFails: Bool = false,
                         settingsFail: Bool = false,
                         bridgeFails: Bool = false) -> TunnelBringUp {
        TunnelBringUp(
            startCore: { log.add("ядро+"); if coreFails { throw Boom() } },
            applySettings: { log.add("настройки+"); if settingsFail { throw Boom() } },
            startBridge: { log.add("мост+"); if bridgeFails { throw Boom() } },
            stopCore: { log.add("ядро−") },
            clearSettings: { log.add("настройки−") },
            stopBridge: { log.add("мост−") }
        )
    }

    func test_successful_start_follows_the_order_from_the_plan() async throws {
        let log = Log()
        try await bringUp(log).run()
        XCTAssertEqual(log.steps, ["ядро+", "настройки+", "мост+"])
    }

    func test_core_failure_leaves_nothing_running() async {
        let log = Log()
        await XCTAssertThrowsErrorAsync(try await bringUp(log, coreFails: true).run())
        // Ядро не поднялось — снимать нечего, настройки не трогали.
        XCTAssertEqual(log.steps, ["ядро+"])
    }

    func test_settings_failure_takes_the_core_down() async {
        let log = Log()
        await XCTAssertThrowsErrorAsync(try await bringUp(log, settingsFail: true).run())
        XCTAssertEqual(log.steps, ["ядро+", "настройки+", "ядро−"])
    }

    func test_bridge_failure_clears_settings_and_core() async {
        let log = Log()
        await XCTAssertThrowsErrorAsync(try await bringUp(log, bridgeFails: true).run())
        // Настройки снимаются явно: иначе система держит маршруты на мёртвом
        // туннеле до собственного таймаута, и человек остаётся без сети.
        XCTAssertEqual(log.steps, ["ядро+", "настройки+", "мост+", "настройки−", "ядро−"])
    }

    func test_stop_goes_in_reverse_order() async {
        let log = Log()
        await bringUp(log).stop()
        // Мост первым: он держит дескриптор туннеля, и погасив ядро раньше,
        // получили бы мост, качающий пакеты в никуда.
        XCTAssertEqual(log.steps, ["мост−", "ядро−"])
    }
}

/// XCTAssertThrowsError не умеет async — крошечная замена.
func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("ожидалась ошибка, её не было", file: file, line: line)
    } catch {
        // так и надо
    }
}
#endif
