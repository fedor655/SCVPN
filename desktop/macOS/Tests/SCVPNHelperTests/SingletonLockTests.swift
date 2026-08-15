import XCTest
@testable import SCVPNHelperKit

final class SingletonLockTests: XCTestCase {

    func test_second_lock_on_same_path_fails() throws {
        let path = try makeTmp().appendingPathComponent("l").path
        let first = try SingletonLock(path: path)
        XCTAssertThrowsError(try SingletonLock(path: path))
        // Держим первый живым до конца проверки: без этого ARC мог бы закрыть
        // дескриптор раньше второго захвата, и проверка проверяла бы не то.
        withExtendedLifetime(first) {}
    }

    func test_lock_is_released_when_object_dies() throws {
        let path = try makeTmp().appendingPathComponent("l").path
        do { _ = try SingletonLock(path: path) }
        XCTAssertNoThrow(try SingletonLock(path: path))
    }

    func test_different_paths_do_not_collide() throws {
        let tmp = try makeTmp()
        let a = try SingletonLock(path: tmp.appendingPathComponent("a").path)
        let b = try SingletonLock(path: tmp.appendingPathComponent("b").path)
        withExtendedLifetime((a, b)) {}
    }

    func test_lock_file_is_not_world_readable() throws {
        let path = try makeTmp().appendingPathComponent("l").path
        let lock = try SingletonLock(path: path)
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        withExtendedLifetime(lock) {}
    }
}
