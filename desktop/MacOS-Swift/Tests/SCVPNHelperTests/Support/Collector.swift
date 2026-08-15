import Foundation

/// Собиратель строк, в который пишут из чужих потоков.
///
/// Читатель stdout живёт своим потоком, а проверка смотрит на результат из
/// своего — без замка это гонка данных, которая падает не там, где ошибка.
final class Collector {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(s)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func contains(_ needle: String) -> Bool {
        all.contains { $0.contains(needle) }
    }

    /// Дождаться строки. Возвращает `false`, если так и не пришла.
    func wait(for needle: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
