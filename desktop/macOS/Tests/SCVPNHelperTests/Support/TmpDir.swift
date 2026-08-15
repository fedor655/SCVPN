import Foundation
import XCTest

/// Временная папка, убирающая за собой.
///
/// Путь берём короткий (`/tmp/scvpn-stand-…`), а не из `NSTemporaryDirectory()`:
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
    sweepStaleStands()
    let name = String(UUID().uuidString.prefix(8))
    let base = URL(fileURLWithPath: "/tmp/scvpn-stand-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    liveDirs.add(base)
    return base
}

/// Папки этого прогона, сносимые на выходе.
///
/// `atexit` покрывает нормальный конец, сметатель ниже — конец по сигналу, до
/// которого `atexit` не доживает. Нужны оба: без первого мусор копится каждым
/// прогоном, без второго остаётся навсегда после падения.
private final class LiveDirs {
    static let shared = LiveDirs()
    private var dirs: [URL] = []
    private let lock = NSLock()

    init() {
        atexit { LiveDirs.shared.removeAll() }
    }

    func add(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        dirs.append(url)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs.removeAll()
    }
}

private var liveDirs: LiveDirs { LiveDirs.shared }

private let sweepOnce: Void = {
    // Прогон, упавший по сигналу, до tearDown не доходит и оставляет папку
    // стенда в /tmp. Общего teardown у SPM-проверок нет, заводить ради `rm -rf`
    // XCTestObservation — дороже задачи. Сносим чужой мусор старше часа при
    // первом же создании папки: час заведомо больше самого долгого прогона,
    // поэтому параллельный запуск проверок себе ничего не снесёт.
    let fm = FileManager.default
    let hourAgo = Date().addingTimeInterval(-3600)
    let names = (try? fm.contentsOfDirectory(atPath: "/tmp")) ?? []
    for name in names where name.hasPrefix("scvpn-stand-") {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let created, created < hourAgo {
            try? fm.removeItem(at: url)
        }
    }
}()

private func sweepStaleStands() { _ = sweepOnce }

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
