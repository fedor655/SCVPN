import Foundation

/// Исходящие сообщения клиенту. Отправка не должна доставать до sing-box.
///
/// Логи sing-box идут клиенту по этому же соединению: читатель stdout -> say ->
/// отправка. Если писать прямо из читателя и клиент перестанет читать, `write`
/// встанет, труба переполнится — и заблокируется сам sing-box. Связь получается
/// такая: поведение клиентского сокета управляет ядром, поднимающим туннель.
/// Поэтому пишет отдельный поток, а очередь ограничена.
///
/// Но выбрасывать при переполнении можно только логи. Ответ на команду
/// выбрасывать нельзя ни при каких обстоятельствах: клиент его ждёт, и
/// потерянный ответ на `start` оставляет приложение в убеждении, что туннеля
/// нет, — пока весь трафик системы идёт в туннель. Для ответа место
/// освобождается за счёт самого старого лога, а не за счёт ответа.
///
/// Но у «не выбрасываем» обязан быть предел. Если клиент не читает, а логов, за
/// счёт которых можно освободить место, в очереди нет, — расти дальше некуда:
/// это память root-процесса. На `hardLimit` кадрах разговор заканчивается.
public final class Outbox {
    private let fd: Int32
    private let maxSize: Int
    /// Запас сверх обычного потолка на случай, когда выбрасывать нечего.
    private let hardLimit: Int
    private let log: (String) -> Void

    private let cv = NSCondition()
    private var items: [[String: Any]] = []
    /// Сколько в очереди логов. Без счётчика поиск «самого старого лога»
    /// обходил бы всю очередь впустую на каждом кадре, когда логов в ней нет.
    private var logCount = 0
    private var closed = false
    private var overflowed = false
    private var droppedCount = 0
    private var thread: Thread?

    public init(fd: Int32, maxSize: Int = outboxLimit, log: @escaping (String) -> Void) {
        self.fd = fd
        self.maxSize = maxSize
        self.hardLimit = maxSize * 4
        self.log = log
        disableSigpipe(fd)
    }

    @discardableResult
    public func start() -> Outbox {
        let t = Thread { [weak self] in self?.run() }
        t.stackSize = 512 * 1024
        thread = t
        t.start()
        return self
    }

    public var pending: Int {
        cv.lock(); defer { cv.unlock() }
        return items.count
    }

    public var dropped: Int {
        cv.lock(); defer { cv.unlock() }
        return droppedCount
    }

    public var isClosed: Bool {
        cv.lock(); defer { cv.unlock() }
        return closed
    }

    /// Слепок очереди — для проверок. Читать состояние иначе значило бы
    /// заводить гонку в самой проверке.
    public func snapshot() -> [[String: Any]] {
        cv.lock(); defer { cv.unlock() }
        return items
    }

    /// Ответ клиенту. Не блокирует, не бросает и не выбрасывается.
    public func send(_ obj: [String: Any]) { put(obj, droppable: false) }

    /// Строка лога. Всё то же самое, но при тесноте её и выбрасываем.
    public func sendLog(_ obj: [String: Any]) { put(obj, droppable: true) }

    private func put(_ obj: [String: Any], droppable: Bool) {
        cv.lock(); defer { cv.unlock() }
        if closed { return }
        if items.count >= maxSize {
            if droppable {
                noteDrop()
                return
            }
            // Ответу место освобождаем за счёт самого старого лога.
            if logCount > 0 {
                dropOldestLog()
                noteDrop()
            } else if items.count >= hardLimit {
                overflow()
                return
            }
        }
        items.append(obj)
        if obj["log"] != nil { logCount += 1 }
        cv.signal()
    }

    /// Клиент не читает ответы, а выбрасывать нечего. Заканчиваем разговор.
    private func overflow() {
        if overflowed { return }
        overflowed = true
        closed = true
        log("очередь ответов переполнена (\(items.count) кадров) — "
            + "клиент не читает, закрываю соединение")
        // shutdown, а не close: читатель обслуживающего потока получит EOF,
        // уйдёт в свою уборку, а уборка и есть dead-man's switch.
        shutdown(fd, SHUT_RDWR)
        cv.signal()
    }

    private func dropOldestLog() {
        if let i = items.firstIndex(where: { $0["log"] != nil }) {
            items.remove(at: i)
            logCount -= 1
            return
        }
        logCount = 0
    }

    private func noteDrop() {
        droppedCount += 1
        if droppedCount == 1 {
            log("клиент не читает сокет — выбрасываю логи, чтобы не тормозить sing-box")
        }
    }

    /// Дать писателю дослать очередь и уйти.
    public func close(timeout: TimeInterval = 2.0) {
        cv.lock()
        closed = true
        cv.signal()
        cv.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        while let t = thread, !t.isFinished, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func run() {
        while true {
            cv.lock()
            while items.isEmpty && !closed { cv.wait() }
            if items.isEmpty {
                cv.unlock()
                return
            }
            let obj = items.removeFirst()
            if obj["log"] != nil { logCount -= 1 }
            cv.unlock()

            // Без .prettyPrinted: перевод строки внутри кадра сломал бы
            // построчное разграничение протокола.
            //
            // Про «кривые байты»: в тексте ошибки лежит то, что прислал
            // клиент. В Python там мог оказаться одиночный суррогат, на
            // котором строгий encode падал и ронял соединение, то есть снимал
            // туннель из-за одного кривого имени в запросе. Swift `String`
            // невалидного UTF-8 не содержит по построению, так что этой
            // проблемы здесь просто нет.
            guard JSONSerialization.isValidJSONObject(obj),
                  var data = try? JSONSerialization.data(withJSONObject: obj,
                                                         options: [.withoutEscapingSlashes]) else {
                log("не смог сериализовать кадр — пропускаю")
                continue
            }
            data.append(UInt8(ascii: "\n"))
            if !writeAll(fd, data) { return }
        }
    }
}

/// Отключить SIGPIPE на этом дескрипторе.
///
/// Иначе запись в сокет, чей другой конец закрылся, убивает **весь процесс**
/// сигналом, а процесс здесь — root-овый демон, стерегущий sing-box. Клиент,
/// закрывший соединение в неудачный момент, сносил бы демона, sing-box
/// оставался бы сиротой с маршрутами, и выглядело бы это как пропавший
/// интернет. В Python этой ямы не было: там SIGPIPE по умолчанию заглушён и
/// приходит как `BrokenPipeError`, который весь код и ловил.
///
/// `SO_NOSIGPIPE` — способ macOS; `MSG_NOSIGNAL` тут не поддержан.
public func disableSigpipe(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Записать всё до последнего байта. `write` имеет право записать меньше.
@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        while sent < raw.count {
            let n = write(fd, base.advanced(by: sent), raw.count - sent)
            if n <= 0 {
                if errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }
}
