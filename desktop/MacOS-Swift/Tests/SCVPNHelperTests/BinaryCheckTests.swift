import XCTest
@testable import SCVPNHelperKit

final class BinaryCheckTests: XCTestCase {

    /// binDir с исполняемым файлом внутри. Владельца root в проверках не
    /// подделать (для этого нужен root), поэтому проверки на владельца ниже
    /// проверяют, что она вообще есть, а не что она пропускает.
    private func makeBinDirWithExecutable(mode: mode_t) throws -> (bin: URL, exe: URL) {
        let tmp = try makeTmp()
        let bin = tmp.appendingPathComponent("bin")
        let exe = bin.appendingPathComponent("sing-box")
        try writeFile(exe, contents: "#!/bin/sh\n", mode: mode)
        return (bin, exe)
    }

    func test_refuses_missing_binary() throws {
        let tmp = try makeTmp()
        XCTAssertThrowsError(try checkBinary(tmp.appendingPathComponent("bin/sing-box"),
                                             binDir: tmp.appendingPathComponent("bin")))
    }

    func test_refuses_binary_outside_its_dir() throws {
        let tmp = try makeTmp()
        let outside = tmp.appendingPathComponent("sing-box")
        try writeFile(outside, mode: 0o755)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try checkBinary(outside, binDir: tmp.appendingPathComponent("bin")))
    }

    func test_refuses_user_writable_binary() throws {
        let (bin, exe) = try makeBinDirWithExecutable(mode: 0o777)
        XCTAssertThrowsError(try checkBinary(exe, binDir: bin)) { error in
            XCTAssertTrue("\(error)".contains("на запись"), "\(error)")
        }
    }

    func test_refuses_group_writable_binary() throws {
        let (bin, exe) = try makeBinDirWithExecutable(mode: 0o775)
        XCTAssertThrowsError(try checkBinary(exe, binDir: bin)) { error in
            XCTAssertTrue("\(error)".contains("на запись"), "\(error)")
        }
    }

    func test_refuses_non_executable_binary() throws {
        let (bin, exe) = try makeBinDirWithExecutable(mode: 0o644)
        XCTAssertThrowsError(try checkBinary(exe, binDir: bin)) { error in
            XCTAssertTrue("\(error)".contains("не исполняемый"), "\(error)")
        }
    }

    func test_refuses_binary_not_owned_by_root() throws {
        // Проверка на владельца стоит последней намеренно: стой она первой,
        // она срабатывала бы на любом пользовательском файле и накрывала бы
        // собой остальные — включая проверки выше, которые гоняются не от root.
        let (bin, exe) = try makeBinDirWithExecutable(mode: 0o755)
        try XCTSkipIf(geteuid() == 0, "прогон от root: файл и так будет root-овым")
        XCTAssertThrowsError(try checkBinary(exe, binDir: bin)) { error in
            XCTAssertTrue("\(error)".contains("не принадлежит root"), "\(error)")
        }
    }

    func test_resolves_symlinks_before_checking_location() throws {
        // Симлинк внутри binDir, ведущий наружу, обязан быть отклонён:
        // проверяем канонический путь, а не тот, что прислали.
        let (bin, _) = try makeBinDirWithExecutable(mode: 0o755)
        let link = bin.appendingPathComponent("sing-box-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try checkBinary(link, binDir: bin)) { error in
            XCTAssertTrue("\(error)".contains("вне"), "\(error)")
        }
    }

    func test_prefix_match_is_not_fooled_by_a_sibling_directory() throws {
        // «bin» и «bin-чужой» начинаются одинаково: сравнение без разделителя
        // пустило бы бинарник из соседней папки.
        let tmp = try makeTmp()
        let bin = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sneaky = tmp.appendingPathComponent("bin-чужой/sing-box")
        try writeFile(sneaky, mode: 0o755)
        XCTAssertThrowsError(try checkBinary(sneaky, binDir: bin))
    }
}
