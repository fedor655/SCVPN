import XCTest
@testable import SCVPNHelperKit

/// Проверки plist, который едет внутрь бандла. Он не код, но держит инварианты
/// не хуже кода, а править его руками легче, чем код, — значит и сверять надо.
final class BundledPlistTests: XCTestCase {

    private func bundledHelperPlist() throws -> [String: Any] {
        // Путь от исходника проверки, а не от Bundle: ресурс лежит рядом с
        // Package.swift, а не внутри тестового бандла.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/SCVPNHelperTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MacOS-Swift
        let url = root.appendingPathComponent("Resources/com.scvpn.helper.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func test_bundled_plist_exit_timeout_covers_worst_case_stop() throws {
        // Расчёт живёт в комментарии plist, но комментарий никто не гоняет.
        // Пересчитываем худший случай по фактическим константам демона: stop()
        // уже поднятого sing-box внутри start() (stopGrace + killGrace) +
        // подметание сироты под тем же замком (2 * sweepGrace) + ещё один
        // stop() основным потоком после освобождения замка (stopGrace +
        // killGrace). Если кто-то поднимет константы демона и забудет про
        // ExitTimeOut, эта проверка упадёт — а иначе launchd ударил бы SIGKILL
        // на середине снятия и оставил sing-box сиротой с маршрутами.
        let worstCase = (productionStopGrace + productionKillGrace)
            + 2 * productionSweepGrace
            + (productionStopGrace + productionKillGrace)
        let exitTimeout = try XCTUnwrap(bundledHelperPlist()["ExitTimeOut"] as? Int)
        XCTAssertEqual(exitTimeout, 40)
        XCTAssertGreaterThan(Double(exitTimeout), worstCase,
                             "ExitTimeOut не перекрывает худший случай снятия (\(worstCase) с)")
    }

    func test_bundled_plist_keeps_the_daemon_alive() throws {
        // Инвариант 7: демон обязан пережить собственное падение, иначе
        // sing-box остаётся без надзора.
        XCTAssertEqual(try bundledHelperPlist()["KeepAlive"] as? Bool, true)
        XCTAssertEqual(try bundledHelperPlist()["RunAtLoad"] as? Bool, true)
    }

    func test_bundled_plist_label_matches_its_filename() throws {
        // Требование SMAppService: имя файла обязано совпадать с Label.
        XCTAssertEqual(try bundledHelperPlist()["Label"] as? String, "com.scvpn.helper")
    }

    func test_bundled_plist_points_inside_the_bundle() throws {
        // BundleProgram, а не ProgramArguments: абсолютный путь ломался бы при
        // каждом переезде .app, а launchd с KeepAlive вечно перезапускал бы
        // несуществующий путь.
        XCTAssertEqual(try bundledHelperPlist()["BundleProgram"] as? String,
                       "Contents/MacOS/scvpn-helper")
        XCTAssertNil(try bundledHelperPlist()["ProgramArguments"])
    }
}
