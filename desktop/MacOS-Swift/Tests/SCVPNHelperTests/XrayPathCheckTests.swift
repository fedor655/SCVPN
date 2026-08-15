import XCTest
@testable import SCVPNHelperKit

final class XrayPathCheckTests: XCTestCase {

    private func makeXray(name: String = "xray", mode: mode_t) throws -> URL {
        let tmp = try makeTmp()
        return try writeFile(tmp.appendingPathComponent(name), contents: "#!/bin/sh\n", mode: mode)
    }

    func test_rejects_symlink_named_xray_pointing_at_shell() throws {
        // Ровно тот обход, который эта функция обязана закрыть: раньше имя
        // проверялось ДО канонизации, и симлинк с именем xray, ведущий на
        // /bin/sh, уезжал в правило process_path как /bin/sh.
        let tmp = try makeTmp()
        let link = tmp.appendingPathComponent("xray")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try checkedXrayPath(link.path)) { error in
            XCTAssertTrue("\(error)".contains("sh"), "\(error)")
        }
    }

    func test_rejects_relative_path() {
        XCTAssertThrowsError(try checkedXrayPath("bin/xray"))
        XCTAssertThrowsError(try checkedXrayPath("./xray"))
    }

    func test_rejects_non_string() {
        XCTAssertThrowsError(try checkedXrayPath(nil))
        XCTAssertThrowsError(try checkedXrayPath(17))
        XCTAssertThrowsError(try checkedXrayPath(["/tmp/xray"]))
    }

    func test_rejects_missing_file() throws {
        let tmp = try makeTmp()
        XCTAssertThrowsError(try checkedXrayPath(tmp.appendingPathComponent("xray").path))
    }

    func test_rejects_wrong_name() throws {
        let exe = try makeXray(name: "xrayy", mode: 0o755)
        XCTAssertThrowsError(try checkedXrayPath(exe.path))
    }

    func test_rejects_a_directory() throws {
        let tmp = try makeTmp()
        let dir = tmp.appendingPathComponent("xray")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try checkedXrayPath(dir.path)) { error in
            XCTAssertTrue("\(error)".contains("не файл"), "\(error)")
        }
    }

    func test_rejects_group_writable_core() throws {
        let exe = try makeXray(mode: 0o775)
        XCTAssertThrowsError(try checkedXrayPath(exe.path))
    }

    func test_rejects_world_writable_core() throws {
        let exe = try makeXray(mode: 0o757)
        XCTAssertThrowsError(try checkedXrayPath(exe.path))
    }

    func test_accepts_plain_user_owned_xray() throws {
        // Требования root-владельца здесь намеренно нет: ядро лежит в папке
        // самого пользователя и ему же принадлежит.
        let exe = try makeXray(mode: 0o755)
        // Возвращается канонический путь: именно он уедет в правило
        // process_path, а не то, что прислал клиент.
        XCTAssertEqual(try checkedXrayPath(exe.path), realPath(exe.path))
    }

    func test_accepts_non_executable_xray() throws {
        // Бит исполнения здесь не проверяется намеренно: его ставит
        // CoreDownloader после распаковки, а отказ на этом месте увёл бы
        // пользователя в «путь неверный» вместо честного «ядро не скачано».
        let exe = try makeXray(mode: 0o644)
        // Возвращается канонический путь: именно он уедет в правило
        // process_path, а не то, что прислал клиент.
        XCTAssertEqual(try checkedXrayPath(exe.path), realPath(exe.path))
    }
}
