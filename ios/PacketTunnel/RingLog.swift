import Foundation

/// Кольцевой буфер последних строк.
///
/// Полноценного лога у расширения нет намеренно: оно живёт в лимите 50 МБ, и
/// неограниченный список строк — это утечка памяти с красивым названием.
final class RingLog {
    private let capacity: Int
    private let lock = NSLock()
    private var lines: [String] = []

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
