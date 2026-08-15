import XCTest
@testable import SCVPNCore

/// Единственная проверка, которая правит системный прокси **на этой машине**.
///
/// Так и задумано планом: молча сломанный откат оставляет пользователя без
/// интернета, и ловить это надо здесь, а не по жалобе. Поддельная сеть из
/// `SystemProxyTests` проверяет правила, но не то, что настоящий
/// `networksetup` понимает наши аргументы.
///
/// Отклонение от плана — предохранитель. Прогон пропускается, если на машине
/// уже стоит чужой прокси: у владельца этой машины рядом живут Happ и подобные,
/// и падение посреди проверки оставило бы **их** настройку затёртой. План этого
/// случая не предусматривал, а разница между «проверка упала» и «у пользователя
/// пропал интернет» слишком велика, чтобы её игнорировать.
final class SystemProxyLiveTests: StorageIsolatedTestCase {

    private func realServices() -> [String] {
        SystemProxy.hardwareServices()
    }

    func test_snapshot_round_trip_restores_state_for_real() throws {
        let services = realServices()
        try XCTSkipIf(services.isEmpty, "нет активных сетевых сервисов")

        // Предохранитель: чужой прокси не трогаем вовсе.
        for service in services {
            let web = SystemProxy.readState(service).kinds["web"] ?? [:]
            try XCTSkipIf(web["Enabled"] == "Yes",
                          "на \(service) уже стоит прокси — чужую настройку не трогаем")
        }

        let before = services.map { SystemProxy.readState($0) }

        try SystemProxy.enable(host: "127.0.0.1", port: 10809)
        // Убедимся, что настоящий networksetup нас понял, а не съел аргументы
        // молча: иначе откат «восстановил» бы то, чего не менял.
        XCTAssertTrue(SystemProxy.systemProxyIsOurs(),
                      "networksetup не принял наши аргументы")

        SystemProxy.disable()
        let after = services.map { SystemProxy.readState($0) }
        XCTAssertEqual(before, after, "откат не вернул состояние сети")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SystemProxy.snapshotFile.path))
    }
}
