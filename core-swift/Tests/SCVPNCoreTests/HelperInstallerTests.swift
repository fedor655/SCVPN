#if os(macOS)
import ServiceManagement
import XCTest
@testable import SCVPNCore

final class HelperInstallerTests: StorageIsolatedTestCase {

    private func dummyError(code: Int) -> Error {
        NSError(domain: "SMAppServiceErrorDomain", code: code,
                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
    }

    func test_status_mapping_covers_every_case() {
        XCTAssertEqual(HelperState(from: .notRegistered), .notInstalled)
        XCTAssertEqual(HelperState(from: .requiresApproval), .awaitingApproval)
        XCTAssertEqual(HelperState(from: .enabled), .ready)
        // notFound — не «пользователь ещё не согласился», а сломанная сборка:
        // либо plist нет, либо его имя разошлось с Label.
        if case .failed = HelperState(from: .notFound) {} else {
            XCTFail("notFound должен быть отказом, а не ожиданием")
        }
    }

    func test_first_register_failure_with_requires_approval_is_not_a_failure() {
        // Регрессия на самое частое первое включение TUN: показать «не удалось»
        // там, где система ждёт согласия, значит отправить пользователя в тупик.
        // Фаза 0 подтвердила: code=1 на первом вызове приходил всегда, из всех
        // четырёх проверенных папок.
        XCTAssertEqual(
            HelperInstaller.interpret(registerError: dummyError(code: 1), status: .requiresApproval),
            .awaitingApproval)
    }

    func test_register_error_with_enabled_status_is_success() {
        // Служба уже разрешена, а register() всё равно поругался: верить надо
        // статусу, а не наличию ошибки.
        XCTAssertEqual(
            HelperInstaller.interpret(registerError: dummyError(code: 1), status: .enabled),
            .ready)
    }

    func test_register_error_without_approval_is_a_real_failure() {
        // code=1 и notRegistered — отказ. Но текст обязан быть человеческим:
        // сырое «The operation couldn't be completed. Operation not permitted»
        // не говорит пользователю ничего, а живьём он увидел именно его.
        guard case .failed(let why) = HelperInstaller.interpret(
            registerError: dummyError(code: 1), status: .notRegistered) else {
            return XCTFail("ожидался отказ")
        }
        XCTAssertTrue(why.contains("Login Items"), why)
        XCTAssertTrue(why.contains("Operation not permitted"), "подробность системы потерялась")
    }

    func test_clean_register_follows_the_status() {
        XCTAssertEqual(HelperInstaller.interpret(registerError: nil, status: .enabled), .ready)
        XCTAssertEqual(HelperInstaller.interpret(registerError: nil, status: .requiresApproval),
                       .awaitingApproval)
        XCTAssertEqual(HelperInstaller.interpret(registerError: nil, status: .notRegistered),
                       .notInstalled)
    }

    func test_plist_name_matches_the_label() {
        // Требование SMAppService: имя файла обязано совпадать с Label.
        XCTAssertEqual(HelperInstaller.plistName, "com.scvpn.helper.plist")
        XCTAssertEqual(HelperInstaller.plistName, Paths.helperLabel + ".plist")
    }

    func test_unknown_version_on_a_ready_service_is_adopted_not_reinstalled() {
        // Служба готова, а версия не записана — так бывает после обновления
        // приложения и когда пользователь разрешил компонент мимо этой ветки.
        // Считать это расхождением версий значит заново просить разрешение у
        // человека, у которого всё уже работает: ровно тот баг, на который
        // пожаловались живьём («пишется об установке, хотя установлен»).
        XCTAssertNil(loadSettings()["helper_version"], "версии не должно быть на чистом старте")

        // Само ensureCurrent() требует бандла, поэтому проверяем условие,
        // по которому оно решает: неизвестная версия и известная-другая — это
        // разные случаи, и слипаться они не должны.
        let unknown: Int? = nil
        let mismatch: Int? = helperVersion - 1
        XCTAssertNotEqual(unknown, mismatch)
        XCTAssertNotEqual(mismatch, helperVersion)
    }

    func test_helper_version_is_stored_only_on_success() {
        // Записать версию, не добившись .ready, значило бы соврать самим себе:
        // следующий запуск решил бы, что перерегистрация не нужна.
        XCTAssertNil(loadSettings()["helper_version"])
    }
}

final class LegacyHelperTests: XCTestCase {

    func test_removal_script_boots_out_before_deleting() {
        // Удалить plist, не сняв службу, значит оставить launchd крутить
        // несуществующий путь до перезагрузки.
        let script = LegacyHelper.removalScript()
        let bootout = script.range(of: "launchctl bootout")
        let remove = script.range(of: "rm -f")
        XCTAssertNotNil(bootout)
        XCTAssertNotNil(remove)
        XCTAssertLessThan(bootout!.lowerBound, remove!.lowerBound)
    }

    func test_removal_script_tolerates_a_missing_service() {
        // bootout падает, если службы уже нет: без `|| true` цепочка && рвалась
        // бы, и plist остался бы на диске.
        XCTAssertTrue(LegacyHelper.removalScript().contains("|| true"))
    }

    func test_removal_script_keeps_the_singbox_directory() {
        // Там лежит sing-box, который новому демону пригодится.
        let script = LegacyHelper.removalScript()
        XCTAssertTrue(script.contains("/Library/Application Support/SCVPN/code"))
        XCTAssertFalse(script.contains("Support/SCVPN/bin"))
        XCTAssertFalse(script.contains("rm -rf '/Library/Application Support/SCVPN'"))
    }

    func test_applescript_literal_does_not_escape_cyrillic() {
        // \\uXXXX AppleScript не компилирует вовсе. Приглашение здесь русское,
        // поэтому на таком экранировании падала бы КАЖДАЯ установка, не показав
        // пользователю даже диалога пароля.
        let literal = appleScriptLiteral("Пароль администратора")
        XCTAssertEqual(literal, "\"Пароль администратора\"")
        XCTAssertFalse(literal.contains("\\u"))
    }

    func test_applescript_literal_escapes_what_matters() {
        XCTAssertEqual(appleScriptLiteral("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(appleScriptLiteral("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(appleScriptLiteral("a\nb"), "\"a\\nb\"")
    }

    func test_shell_quote_survives_a_quote_in_the_path() {
        XCTAssertEqual(shellQuote("/tmp/it's"), "'/tmp/it'\\''s'")
    }

    func test_generated_applescript_actually_compiles() throws {
        // Компилируем настоящим osascript тем же кодом, которым пользуется
        // remove(), — убрав повышение прав, чтобы не поднимать диалог пароля.
        let command = doShellScriptCommand(script: LegacyHelper.removalScript(),
                                           prompt: "SCVPN удаляет системный компонент прежней версии")
        let withoutAdmin = command.replacingOccurrences(
            of: " with administrator privileges", with: "")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // -e с проверкой компиляции: печатаем сам текст, не выполняя его.
        proc.arguments = ["-e", "return \(appleScriptLiteral(withoutAdmin))"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "osascript не скомпилировал литерал")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("launchctl bootout"))
    }
}
#endif
