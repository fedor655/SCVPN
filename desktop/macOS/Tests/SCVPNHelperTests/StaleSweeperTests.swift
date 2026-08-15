import XCTest
@testable import SCVPNHelperKit

final class StaleSweeperTests: XCTestCase {

    func test_sweeps_stubborn_orphan_at_start() throws {
        // Ждём факта смерти, а не отправки сигнала: pkill возвращается сразу,
        // и рапорт об успехе при живой сироте означал бы второй sing-box рядом
        // с первым, дерущийся за default route.
        let stand = try Stand(script: .stubborn)
        defer { stand.tearDown() }
        try stand.spawnOrphan()
        XCTAssertTrue(killStaleSingbox(stand.env))
        XCTAssertTrue(stand.waitGone(timeout: 5))
    }

    func test_sweeps_ordinary_orphan_at_start() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        try stand.spawnOrphan()
        XCTAssertTrue(killStaleSingbox(stand.env))
        XCTAssertTrue(stand.waitGone(timeout: 5))
    }

    func test_reports_success_when_there_is_nothing_to_sweep() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        XCTAssertTrue(killStaleSingbox(stand.env))
    }

    func test_reports_failure_when_it_cannot_look() throws {
        // «Не смог посмотреть» — это false, а не true. Неизвестность ничем не
        // лучше живой сироты: решение по этому ответу принимается одно и то же.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        var env = stand.env
        env.procTool = { _ in nil }
        XCTAssertFalse(killStaleSingbox(env))
    }

    func test_reports_failure_when_pgrep_returns_an_error_code() throws {
        // 0 — нашлось, 1 — не нашлось. 2 и 3 — кривой шаблон и внутренняя
        // ошибка: молчать про них значит погасить защиту от сироты незаметно.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        var env = stand.env
        env.procTool = { _ in ProcResult(status: 2, stdout: "", stderr: "кривой шаблон") }
        XCTAssertFalse(killStaleSingbox(env))
    }

    func test_reports_failure_when_the_orphan_never_dies() throws {
        // Шаблон подсовываем такой, что pkill по нему никого не находит, а
        // pgrep находит всегда: имитация сироты, пережившей и SIGTERM, и
        // SIGKILL, без реального неубиваемого процесса.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        var env = stand.env
        env.procTool = { args in
            args[0].hasSuffix("pgrep")
                ? ProcResult(status: 0, stdout: "4242\n", stderr: "")
                : ProcResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertFalse(killStaleSingbox(env))
    }

    func test_pattern_is_escaped_for_pgrep_not_for_icu() throws {
        // NSRegularExpression.escapedPattern заворачивает строку в \Q…\E,
        // который pgrep не понимает: шаблон уехал бы туда буквально и не
        // совпал бы ни с чем — защита от сироты погасла бы молча.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let pattern = stalePattern(stand.env)
        XCTAssertFalse(pattern.contains("\\Q"))
        XCTAssertFalse(pattern.contains("\\E"))
        XCTAssertTrue(pattern.contains("sing\\-box"))
    }

    func test_stale_pids_distinguishes_empty_from_unknown() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        XCTAssertEqual(stalePIDs(stand.env), [])
        var env = stand.env
        env.procTool = { _ in nil }
        XCTAssertNil(stalePIDs(env))
    }
}
