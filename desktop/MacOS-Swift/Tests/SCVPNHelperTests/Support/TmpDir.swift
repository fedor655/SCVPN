import Foundation
import XCTest

/// Временная папка, убирающая за собой.
///
/// Путь берём короткий (`/tmp/scvpn-…`), а не из `NSTemporaryDirectory()`:
/// `sockaddr_un.sun_path` — 104 байта, а `/var/folders/xy/…/T/` с UUID в имени
/// съедает их почти целиком, и `bind` падал бы на ровном месте.
///
/// Путь возвращается **неканоническим** (`/tmp/…`, а не `/private/tmp/…`), и
/// это принципиально. `Foundation.Process` при запуске приводит
/// `/private/tmp/x` обратно к `/tmp/x`, и в argv процесса оказывается короткая
/// форма. Стенд ищет свой поддельный sing-box по командной строке через
/// `pgrep -f`; канонизируй мы путь здесь — шаблон говорил бы `/private/tmp`,
/// argv показывал бы `/tmp`, и `killStaleSingbox` в проверках не находил бы
/// ничего. Проверки «не поднимать поверх сироты» при этом зеленели бы, не
/// проверив ровно то свойство, ради которого написаны.
///
/// Сравнения «внутри binDir» от этого не страдают: `checkBinary` канонизирует
/// **обе** стороны через `realpath`.
func makeTmp(_ file: StaticString = #filePath, _ line: UInt = #line) throws -> URL {
    let name = String(UUID().uuidString.prefix(8))
    let base = URL(fileURLWithPath: "/tmp/scvpn-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    TmpRegistry.shared.add(base)
    return base
}

/// Папки живут до конца прогона и сносятся разом: убирать их в `tearDown`
/// каждой проверки значило бы городить общий базовый класс ради `rm -rf`.
final class TmpRegistry {
    static let shared = TmpRegistry()
    private var dirs: [URL] = []
    private let lock = NSLock()

    func add(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        dirs.append(url)
    }

    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs.removeAll()
    }
}

/// Создать файл с точными правами. `FileManager` умеет это одним вызовом, а
/// `chmod` следом — нет: umask срезал бы биты обратно.
@discardableResult
func writeFile(_ url: URL, contents: String = "", mode: mode_t) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
    guard chmod(url.path, mode) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return url
}
