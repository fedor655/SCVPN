import XCTest
@testable import SCVPNCore
@testable import SCVPNHelperKit

final class SupervisorTests: XCTestCase {

    private func params() throws -> SingboxParams {
        try validate(["socks_port": 10808])
    }

    func test_sets_owner_before_the_only_fallible_step_after_launch() throws {
        // Зазор между запуском процесса и выставлением владельца обязан быть
        // пуст. Под launchd stderr — файл, запись в него может отказать
        // (ENOSPC, EIO, сломанная труба); в зазоре получилось бы
        // isRunning == true при owner == nil, и обработчик обрыва не признал
        // бы в соединении владельца и не снял бы туннель.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }

        // Коробка нужна, потому что колбэк лога уезжает в env раньше, чем
        // существует сам Supervisor: замкнуться на него напрямую нельзя.
        final class Box { weak var sup: Supervisor? }
        let box = Box()

        var env = stand.env
        let sawRunningWithoutOwner = Collector()
        let sawLogAfterLaunch = Collector()
        env.log = { msg in
            guard let sup = box.sup, sup.isRunning else { return }
            sawLogAfterLaunch.add(msg)
            if sup.owner == nil { sawRunningWithoutOwner.add(msg) }
        }

        let sup = Supervisor(env: env)
        box.sup = sup
        let conn = ClientHandle(fd: -1)
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: conn)
        defer { sup.stop() }

        XCTAssertTrue(sup.owner === conn)
        XCTAssertFalse(sawLogAfterLaunch.all.isEmpty,
                       "после запуска не было ни одной записи в лог — проверка ничего не проверила")
        XCTAssertTrue(sawRunningWithoutOwner.all.isEmpty,
                      "лог застал состояние «процесс поднят, владельца нет»: \(sawRunningWithoutOwner.all)")
    }

    func test_owner_is_visible_the_moment_start_returns() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let sup = Supervisor(env: stand.env)
        let conn = ClientHandle(fd: -1)
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: conn)
        defer { sup.stop() }
        XCTAssertTrue(sup.isRunning)
        XCTAssertTrue(sup.owner === conn)
    }

    func test_owner_identity_is_by_reference_not_by_fd() throws {
        // Номера дескрипторов переиспользуются: закрывшееся соединение с fd 7
        // сравнялось бы с новым, получившим тот же 7.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let sup = Supervisor(env: stand.env)
        let owner = ClientHandle(fd: 7)
        let impostor = ClientHandle(fd: 7)
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: owner)
        defer { sup.stop() }
        XCTAssertTrue(sup.owner === owner)
        XCTAssertFalse(sup.owner === impostor)
    }

    func test_stop_releases_the_handle_on_an_ordinary_singbox() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let sup = Supervisor(env: stand.env)
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        sup.stop()
        XCTAssertFalse(sup.isRunning)
        XCTAssertNil(sup.owner)
        XCTAssertTrue(stand.waitGone(timeout: 10))
    }

    func test_keeps_handle_on_unkillable_singbox() throws {
        // sing-box имеет право пережить и SIGTERM, и SIGKILL. Обнулять ручку
        // на живом процессе нельзя: isRunning соврал бы false, а следующий
        // start поднял бы второй рядом с первым.
        //
        // Неубиваемого процесса в системе не завести, поэтому подменяем
        // «упрямому» sing-box отведённое время нулём: SIGKILL уйдёт, но ждать
        // подтверждения смерти stop не станет и обязан оставить ручку.
        let stand = try Stand(script: .stubborn)
        defer { stand.tearDown() }
        var env = stand.env
        env.stopGrace = 0.05
        env.killGrace = 0
        let sup = Supervisor(env: env)
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        sup.stop()
        // Проверяем именно ручку, а не живой процесс: SIGKILL всё-таки уйдёт,
        // и через мгновение процесса не станет. Свойство здесь в другом —
        // stop() не имел права записать «снято», не дождавшись подтверждения.
        XCTAssertTrue(sup.isRunning, "ручка отпущена без подтверждённой смерти")
    }

    func test_refuses_to_start_over_a_stale_singbox() throws {
        // Двух sing-box рядом быть не должно: они подерутся за default route.
        let stand = try Stand(script: .stubborn)
        defer { stand.tearDown() }
        try stand.spawnOrphan()
        var env = stand.env
        // Сирота неубиваема на время проверки: подметание обязано не суметь и
        // честно об этом сказать.
        env.procTool = { args in
            args[0].hasSuffix("pgrep")
                ? ProcResult(status: 0, stdout: "4242\n", stderr: "")
                : ProcResult(status: 0, stdout: "", stderr: "")
        }
        let sup = Supervisor(env: env)
        XCTAssertThrowsError(try sup.start(try params(), xrayPath: stand.xrayPath,
                                           onLog: { _ in }, owner: nil)) { error in
            XCTAssertTrue("\(error)".contains("осиротевший"), "\(error)")
        }
        XCTAssertFalse(sup.isRunning)
    }

    func test_refuses_to_start_when_it_cannot_check_for_orphans() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        var env = stand.env
        env.procTool = { _ in nil }
        let sup = Supervisor(env: env)
        XCTAssertThrowsError(try sup.start(try params(), xrayPath: stand.xrayPath,
                                           onLog: { _ in }, owner: nil))
    }

    func test_second_start_replaces_the_first_singbox() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let sup = Supervisor(env: stand.env)
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        let first = stand.singboxPIDs()

        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil)
        defer { sup.stop() }
        XCTAssertTrue(stand.waitUp(timeout: 10))
        let second = stand.singboxPIDs()
        XCTAssertEqual(second.count, 1, "рядом оказались два sing-box: \(second)")
        XCTAssertNotEqual(first, second)
    }

    func test_log_callback_is_per_start_not_per_supervisor() throws {
        // Колбэк передаётся аргументом, а не читается из поля: после рестарта
        // «sing-box завершился» от старого процесса ушло бы новому клиенту,
        // как будто это про его туннель.
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let sup = Supervisor(env: stand.env)

        let firstSaw = Collector(), secondSaw = Collector()
        try sup.start(try params(), xrayPath: stand.xrayPath,
                      onLog: { firstSaw.add($0) }, owner: nil)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        try sup.start(try params(), xrayPath: stand.xrayPath,
                      onLog: { secondSaw.add($0) }, owner: nil)
        defer { sup.stop() }
        XCTAssertTrue(stand.waitUp(timeout: 10))

        // Смерть первого досталась первому колбэку и не досталась второму.
        XCTAssertTrue(firstSaw.wait(for: "завершился"),
                      "первый колбэк не увидел смерти своего процесса: \(firstSaw.all)")
        XCTAssertFalse(secondSaw.contains("завершился"),
                       "смерть чужого процесса ушла новому клиенту: \(secondSaw.all)")
    }

    func test_crashing_singbox_is_reported_and_leaves_no_handle() throws {
        let stand = try Stand(script: .crashing)
        defer { stand.tearDown() }
        let sup = Supervisor(env: stand.env)
        let seen = Collector()
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { seen.add($0) }, owner: nil)

        // Ждём именно сообщения, а не падения isRunning: процесс умирает
        // мгновенно, а читатель stdout доносит код выхода чуть позже.
        XCTAssertTrue(seen.wait(for: "код 7"), "код выхода не доехал до клиента: \(seen.all)")
        XCTAssertFalse(sup.isRunning)
    }

    func test_config_lands_on_disk_unreadable_to_others() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let sup = Supervisor(env: stand.env)
        try sup.start(try params(), xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil)
        defer { sup.stop() }

        var st = stat()
        XCTAssertEqual(stat(stand.env.configPath.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        var dir = stat()
        XCTAssertEqual(stat(stand.env.runDir.path, &dir), 0)
        XCTAssertEqual(dir.st_mode & 0o777, 0o700)

        let raw = try Data(contentsOf: stand.env.configPath)
        let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let rules = (cfg["route"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(rules[0]["process_path"] as? [String], [stand.xrayPath])
    }
}
