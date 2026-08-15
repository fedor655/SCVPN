#if os(macOS)
import XCTest
@testable import SCVPNCore

final class RunningAppsTests: XCTestCase {

    func test_normalize_strips_dot_app_and_path() {
        XCTAssertEqual(RunningApps.normalizeAppName("/Applications/Telegram.app"), "Telegram")
        XCTAssertEqual(RunningApps.normalizeAppName("  Safari.app/  "), "Safari")
        XCTAssertEqual(RunningApps.normalizeAppName("Telegram"), "Telegram")
        XCTAssertEqual(RunningApps.normalizeAppName("/System/Applications/Notes.app/"), "Notes")
    }

    func test_normalize_keeps_a_bare_name_with_dots() {
        // Точка в имени — не повод считать его бандлом.
        XCTAssertEqual(RunningApps.normalizeAppName("com.example.tool"), "com.example.tool")
    }

    func test_normalize_survives_empty_and_slashes() {
        XCTAssertEqual(RunningApps.normalizeAppName(""), "")
        XCTAssertEqual(RunningApps.normalizeAppName("///"), "")
    }

    func test_running_apps_finds_something() {
        // План предлагал проверять наличие Finder. Это неверно: Finder лежит в
        // /System/Library/CoreServices, а не в /System/Applications, и в
        // список не попадает — ни здесь, ни в Python-версии, у которой тот же
        // набор префиксов. Проверяем то, что действительно верно: список не
        // пуст и в нём нет расширений.
        let apps = RunningApps.runningApps()
        XCTAssertFalse(apps.isEmpty, "не нашлось ни одного запущенного приложения")
        XCTAssertFalse(apps.contains { $0.contains("Extension") || $0.contains("Widget") }, "\(apps)")
    }

    func test_running_apps_returns_executable_names_not_bundles() {
        // sing-box сопоставляет соединение с процессом по имени исполняемого
        // файла ВНУТРИ бандла: Telegram, а не Telegram.app.
        for name in RunningApps.runningApps() {
            XCTAssertFalse(name.hasSuffix(".app"), name)
            XCTAssertFalse(name.contains("/"), name)
        }
    }

    func test_running_apps_has_no_duplicates_and_is_sorted() {
        let apps = RunningApps.runningApps()
        XCTAssertEqual(apps.count, Set(apps).count)
        XCTAssertEqual(apps, apps.sorted { $0.lowercased() < $1.lowercased() })
    }

    func test_running_apps_skips_extensions() {
        // .appex — виджеты и шаринг. Это не то, что человек выбирает в списке.
        XCTAssertFalse(RunningApps.runningApps().contains { $0.contains(".appex") })
    }
}

final class CoreDownloaderTests: StorageIsolatedTestCase {

    private func asset(_ name: String) -> [String: Any] {
        ["name": name, "browser_download_url": "https://example.com/\(name)"]
    }

    func test_picks_the_arm64_asset() throws {
        let (tag, url) = try CoreDownloader.pickAsset(tag: "v1.8.0", assets: [
            asset("Xray-macos-64.zip"),
            asset("Xray-linux-arm64-v8a.zip"),
            asset(CoreDownloader.assetName),
        ])
        XCTAssertEqual(tag, "v1.8.0")
        XCTAssertEqual(url.lastPathComponent, CoreDownloader.assetName)
    }

    func test_fails_when_asset_missing_from_release() {
        XCTAssertThrowsError(try CoreDownloader.pickAsset(tag: "v1.8.0",
                                                          assets: [asset("Xray-macos-64.zip")])) { e in
            XCTAssertTrue("\(e)".contains(CoreDownloader.assetName), "\(e)")
        }
        XCTAssertThrowsError(try CoreDownloader.pickAsset(tag: "v1.8.0", assets: []))
    }

    func test_asset_without_a_url_is_refused_loudly() {
        // Имя подходит, ссылки нет: молча вернуть такое значило бы уронить
        // загрузку строкой позже, без внятного объяснения.
        XCTAssertThrowsError(try CoreDownloader.pickAsset(
            tag: "v1", assets: [["name": CoreDownloader.assetName]]))
    }

    func test_unpack_sets_exec_bit_on_xray() throws {
        Paths.ensureDirs()
        // Из zip права не переносятся — распакованный файл приходит без бита
        // исполнения, и ядро молча не запустилось бы.
        for name in CoreDownloader.wanted {
            try writeCoreFile(name, mode: 0o644)
        }
        CoreDownloader.finishUnpacked()

        var st = stat()
        XCTAssertEqual(stat(Paths.xrayExe.path, &st), 0)
        XCTAssertNotEqual(st.st_mode & mode_t(S_IXUSR), 0, "нет бита исполнения")
    }

    func test_unpack_strips_quarantine() throws {
        Paths.ensureDirs()
        for name in CoreDownloader.wanted {
            try writeCoreFile(name, mode: 0o644)
        }
        // Файл с com.apple.quarantine система откажется запускать, а
        // пользователь увидит окно про «неизвестного разработчика».
        let path = Paths.xrayExe.path
        var value: UInt8 = 1
        setxattr(path, "com.apple.quarantine", &value, 1, 0, 0)
        XCTAssertGreaterThan(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0), 0)

        CoreDownloader.finishUnpacked()
        XCTAssertLessThan(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0), 0,
                          "карантин остался")
    }

    func test_core_present_wants_all_three_files() throws {
        Paths.ensureDirs()
        XCTAssertFalse(CoreDownloader.corePresent())
        try writeCoreFile("xray", mode: 0o755)
        // Гео-базы нужны правилам маршрутизации: без них geoip:private и
        // geosite:category-ru не сработают, и локалка уйдёт в туннель.
        XCTAssertFalse(CoreDownloader.corePresent())
        try writeCoreFile("geoip.dat", mode: 0o644)
        XCTAssertFalse(CoreDownloader.corePresent())
        try writeCoreFile("geosite.dat", mode: 0o644)
        XCTAssertTrue(CoreDownloader.corePresent())
    }

    func test_tun_present_does_not_ask_about_the_helper() {
        // Раньше tun_present включал в себя «демон установлен», и на чистой
        // машине из этой вложенности получался неснимаемый круг: префлайт
        // требовал компоненты раньше прав, а компоненты кладёт демон, которого
        // ставила только ветка прав — за уже непроходимым гейтом.
        //
        // Здесь ответ зависит ровно от одного файла на диске.
        XCTAssertEqual(CoreDownloader.tunPresent(),
                       FileManager.default.fileExists(atPath: Paths.singboxExe.path))
    }

    private func writeCoreFile(_ name: String, mode: mode_t) throws {
        let url = Paths.binDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        XCTAssertEqual(chmod(url.path, mode), 0)
    }
}
#endif
