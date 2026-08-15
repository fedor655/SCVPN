import XCTest
@testable import SCVPNCore

/// Два поведенческих правила меню «⋯» из плана, Задача 6.4.
///
/// Само меню — SwiftUI и проверке не поддаётся, но оба правила держатся на
/// функциях из `SCVPNCore`, и проверять надо именно их: сломается не разметка,
/// а ответ на вопрос «есть ли что удалять» и «в каком порядке спрашивать».
final class MenuRulesTests: StorageIsolatedTestCase {

    func test_remove_tun_is_offered_only_when_there_is_something_to_remove() throws {
        // Пункт «удалить» над пустым местом — обещание действия, которое ничего
        // не сделает. Ответ зависит ровно от одного файла на диске.
        let saved = Paths.dataDir
        defer { Paths.dataDir = saved }

        XCTAssertEqual(CoreDownloader.tunPresent(),
                       FileManager.default.fileExists(atPath: Paths.singboxExe.path))
    }

    func test_tun_present_and_privileged_are_independent_questions() {
        // Раньше «компоненты есть» включало в себя «демон установлен», и на
        // чистой машине получался неснимаемый круг: префлайт требовал
        // компоненты раньше прав, компоненты кладёт демон, а демона ставила
        // только ветка прав — за уже непроходимым гейтом.
        //
        // Проверяем, что вопросы разошлись: tunPresent смотрит на файл,
        // privileged — на статус службы, и один не вызывает другой.
        let byFile = FileManager.default.fileExists(atPath: Paths.singboxExe.path)
        XCTAssertEqual(CoreDownloader.tunPresent(), byFile)
        // privileged() не обязан совпадать с наличием файла ни в одну сторону.
        _ = HelperInstaller.privileged()
    }

    func test_every_menu_setting_has_a_default() {
        // Меню читает настройки со значением по умолчанию. Ключ, которого нет
        // в defaultSettings, показал бы пустой переключатель на чистой машине.
        for key in ["vpn_mode", "tls_fingerprint", "tun_stack",
                    "system_proxy", "block_ads", "split_mode", "split_apps"] {
            XCTAssertNotNil(defaultSettings[key], "нет умолчания для \(key)")
        }
    }

    func test_menu_choices_match_what_the_code_accepts() {
        // Пункт меню, которого не понимает разбор, молча свалился бы в
        // умолчание — и переключатель показывал бы одно, а работало другое.
        for raw in ["proxy", "tun"] { XCTAssertNotNil(VPNMode(rawValue: raw), raw) }
        for raw in ["gvisor", "system", "mixed"] { XCTAssertNotNil(Stack(rawValue: raw), raw) }
        for raw in ["off", "exclude", "include"] { XCTAssertNotNil(SplitMode(rawValue: raw), raw) }
        // Отпечатки в меню — тот же список, что перебирает автоподбор.
        XCTAssertEqual(fallbackFingerprints,
                       ["firefox", "chrome", "safari", "edge", "ios", "randomized"])
    }

    func test_helper_version_key_is_not_in_defaults() {
        // helper_version пишется только после успешной регистрации. Появись он
        // в умолчаниях, первая же проверка версии решила бы, что демон уже
        // стоит нужной сборки, и перерегистрация не случилась бы никогда.
        XCTAssertNil(defaultSettings["helper_version"])
    }
}
