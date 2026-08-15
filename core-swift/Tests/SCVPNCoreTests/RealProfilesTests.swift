#if os(macOS)
import XCTest
@testable import SCVPNCore

/// Приёмка Фазы 4, Шаг 2: настоящий `profiles.json` пользователя переживает
/// круг чтение-запись без потерь.
///
/// Проверка сделана постоянной, а не разовой командой из плана: формат на диске
/// заморожен, и потерянное поле — это потерянная подписка, замеченная не
/// сегодня, а когда пользователь не сможет подключиться.
///
/// Файл берётся из рабочего каталога приложения и **не изменяется**: разбор и
/// запись идут в памяти и во временной папке. Файла нет — `XCTSkip`.
final class RealProfilesTests: StorageIsolatedTestCase {

    /// Настоящий файл приложения, а не фикстура в репозитории.
    ///
    /// Путь строится вручную мимо `Paths`: базовый класс подменяет корень
    /// данных временной папкой, и через него сюда не дотянуться — а проверять
    /// надо именно то, что лежит у пользователя.
    private func realProfilesURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SCVPN/profiles.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func test_reads_a_real_profiles_json_without_losing_fields() throws {
        guard let url = realProfilesURL() else {
            throw XCTSkip("profiles.json ещё не заведён — проверять нечего")
        }
        let raw = try Data(contentsOf: url)

        let profiles = try JSONDecoder().decode(Profiles.self, from: raw)
        XCTAssertFalse(profiles.allServers().isEmpty, "файл прочитан, но серверов нет")

        let back = try JSONEncoder().encode(profiles)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? NSDictionary)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: back) as? NSDictionary)
        XCTAssertEqual(before, after, """
            круг чтение-запись изменил файл.
            было:  \(before)
            стало: \(after)
            """)
    }

    func test_every_real_server_builds_an_xray_config() throws {
        guard let url = realProfilesURL() else {
            throw XCTSkip("profiles.json ещё не заведён — проверять нечего")
        }
        let profiles = try JSONDecoder().decode(Profiles.self, from: Data(contentsOf: url))
        for server in profiles.allServers() {
            let cfg = try buildXrayConfig(server: server)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(cfg), server.title)
        }
    }

    func test_every_real_server_has_a_usable_key() throws {
        guard let url = realProfilesURL() else {
            throw XCTSkip("profiles.json ещё не заведён — проверять нечего")
        }
        let profiles = try JSONDecoder().decode(Profiles.self, from: Data(contentsOf: url))
        for server in profiles.allServers() {
            // Ключ лежит в settings.json как selected_key: пустой или
            // повторяющийся означает, что выбранный сервер потеряется.
            XCTAssertFalse(server.key().isEmpty, server.title)
            XCTAssertFalse(server.address.isEmpty, server.title)
        }
    }
}
#endif
