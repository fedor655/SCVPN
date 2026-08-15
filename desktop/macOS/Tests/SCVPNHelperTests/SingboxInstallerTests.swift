import XCTest
import SCVPNCore
@testable import SCVPNHelperKit

final class SingboxInstallerTests: XCTestCase {

    // Живую загрузку здесь не гоняем: это дымовая проверка Фазы 8. Здесь —
    // выбор ассета и отказ при удалении, то есть всё, что не требует сети.

    func test_picks_darwin_arm64_asset() throws {
        let assets: [[String: Any]] = [
            ["name": "sing-box-linux-amd64.tar.gz", "browser_download_url": "нет"],
            ["name": "sing-box-1.9-darwin-amd64.tar.gz", "browser_download_url": "тоже нет"],
            ["name": "sing-box-1.9-darwin-arm64.tar.gz", "browser_download_url": "да"],
        ]
        XCTAssertEqual(try pickSingboxAsset(assets), "да")
    }

    func test_fails_loudly_when_no_darwin_asset() {
        XCTAssertThrowsError(try pickSingboxAsset([["name": "sing-box-windows.zip"]]))
        XCTAssertThrowsError(try pickSingboxAsset([]))
    }

    func test_ignores_asset_without_download_url() {
        // Имя подходит, ссылки нет — молча вернуть такое значило бы уронить
        // установку на кривом URL строкой позже, без внятного объяснения.
        XCTAssertThrowsError(try pickSingboxAsset([["name": "sing-box-darwin-arm64.tar.gz"]]))
    }

    func test_remove_refuses_while_the_tunnel_is_up() throws {
        let stand = try Stand(script: .normal)
        defer { stand.tearDown() }
        let params = try validate(["socks_port": 10808])
        try stand.supervisor.start(params, xrayPath: stand.xrayPath, onLog: { _ in }, owner: nil)
        XCTAssertTrue(stand.waitUp(timeout: 10))
        XCTAssertThrowsError(try removeSingbox(stand.env, sup: stand.supervisor, say: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stand.env.singboxExe.path))
    }

    func test_find_file_walks_the_whole_tree() throws {
        // Архив sing-box кладёт бинарник в подпапку с версией в имени —
        // искать надо по дереву, а не в корне.
        let tmp = try makeTmp()
        let nested = tmp.appendingPathComponent("sing-box-1.9.0-darwin-arm64/sing-box")
        try writeFile(nested, contents: "бинарник", mode: 0o644)
        XCTAssertEqual(findFile(named: "sing-box", under: tmp)?.lastPathComponent, "sing-box")
    }

    func test_find_file_ignores_a_directory_with_the_right_name() throws {
        let tmp = try makeTmp()
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("sing-box"),
                                                withIntermediateDirectories: true)
        XCTAssertNil(findFile(named: "sing-box", under: tmp))
    }
}
