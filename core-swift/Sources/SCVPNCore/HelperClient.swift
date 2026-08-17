// Только macOS: демон, sing-box, системный прокси и дочерние процессы.
// На iOS ничего этого нет — там туннель поднимает NEPacketTunnelProvider.
#if os(macOS)
import Foundation

/// Сколько ждать правдивый ответ демона на команду `stop`.
///
/// Верхняя граница — его собственный бюджет на остановку: 7 с на SIGTERM плюс
/// 3 с на SIGKILL, и запас на дорогу. Дольше ждать нечего: если демон не
/// ответил и за это время, ответа не будет.
public let stopReplyTimeoutSec: TimeInterval = 12.0

public struct HelperClientError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

/// Одно соединение с демоном. Живёт, пока живёт туннель.
///
/// **Дисциплина «единственный читатель сокета» — не стиль, а починенные баги.**
/// До `start()` сокет читает вызывающий поток, после — поток логов. Два
/// читателя на одном сокете отдавали бы строки кому попало, и ответ на `stop`
/// терялся бы, подвешивая `stop()` до таймаута.
///
/// Поэтому кадры сюда приходят в одно место, а раздаются двум потребителям:
/// потоку логов и тому, кто ждёт ответа на `stop`. **Не «улучшать» на ходу.**
public final class HelperConnection {
    private let fd: Int32
    private let onLog: (String) -> Void

    private let lock = NSCondition()
    private var replies: [[String: Any]] = []
    private var streaming = false
    private var closed = false

    public init(socketPath: String = Paths.helperSocket,
                onLog: @escaping (String) -> Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperClientError("не смог создать сокет")
        }
        // Darwin.close явно: у HelperConnection есть свой метод close(), и
        // безымянный вызов внутри init разрешается в него, а не в POSIX.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw HelperClientError("путь сокета слишком длинный: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard ok == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw HelperClientError("""
                Системный компонент не отвечает (\(err)).
                Меню «⋯» → «Переустановить системный компонент».
                """)
        }
        disableSigpipeClient(fd)
        self.fd = fd
        self.onLog = onLog
    }

    /// Отправить команду и дождаться ответа. Строки лога по пути отдаём наружу.
    ///
    /// Годится только пока соединение читает исключительно вызывающий поток —
    /// то есть до того, как запущен поток логов.
    public func request(_ payload: [String: Any], timeout: TimeInterval = 240) throws -> [String: Any] {
        precondition(!streaming, "request() после старта потока логов — два читателя на сокете")
        try send(payload)
        setReadTimeout(timeout)
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                throw HelperClientError("Системный компонент закрыл соединение.")
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[0..<idx])
                buffer.removeSubrange(0...idx)
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if let text = msg["log"] as? String {
                    onLog(text)
                    continue
                }
                return msg
            }
        }
    }

    /// Отправить команду, не читая ответ. Для случая, когда чтение уже занято
    /// потоком логов.
    public func send(_ payload: [String: Any], timeout: TimeInterval = 5) throws {
        var data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.withoutEscapingSlashes])
        data.append(UInt8(ascii: "\n"))
        guard writeAllClient(fd, data) else {
            throw HelperClientError("не смог отправить команду системному компоненту")
        }
    }

    /// Читать кадры до обрыва. Возврат означает, что соединение закрылось.
    ///
    /// Наверх отдаём **все** кадры, а не только `log`. После `start()` этот
    /// читатель единственный на соединении — значит и ответ демона на `stop`
    /// приходит сюда. Отсортируй мы здесь только логи, правдивый ответ на
    /// `stop` («running: true», если sing-box пережил SIGKILL) было бы
    /// физически некому прочитать.
    public func stream(onFrame: ([String: Any]) -> Void) {
        streaming = true
        setReadTimeout(0)
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[0..<idx])
                buffer.removeSubrange(0...idx)
                if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    onFrame(msg)
                }
            }
        }
    }

    /// Положить ответ в очередь для того, кто его ждёт.
    func putReply(_ msg: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        replies.append(msg)
        lock.signal()
    }

    /// Выбросить ответы от прошлых команд — ждём только свой.
    func drainReplies() {
        lock.lock(); defer { lock.unlock() }
        replies.removeAll()
    }

    /// Дождаться ответа от потока логов. `nil` — не дождались.
    func awaitReply(timeout: TimeInterval) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while replies.isEmpty {
            if !lock.wait(until: deadline) { return nil }
        }
        return replies.removeFirst()
    }

    public func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        guard !already else { return }
        // shutdown раньше close: если поток стоит в блокирующем read внутри
        // stream(), одного close() ему может не хватить, чтобы проснуться
        // немедленно. Тот же приём демон применяет к себе на своей стороне.
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    /// Закрыть сокет вместе с объектом.
    ///
    /// Без этого брошенный `Tun` оставлял бы туннель поднятым навсегда:
    /// дескриптор жил бы до конца процесса, демон не увидел бы обрыва, а
    /// dead-man's switch — главное свойство проекта — просто не сработал бы.
    /// В Python сокет закрывал сборщик мусора, в Swift это надо написать.
    deinit {
        close()
    }

    private func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

func disableSigpipeClient(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

@discardableResult
func writeAllClient(_ fd: Int32, _ data: Data) -> Bool {
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

/// Список IP-адресов хоста, v4 и v6. Если host уже IP — вернуть его.
///
/// Обе версии, а не только IPv4: результат уходит в `exclude_ips`, то есть в
/// запасной пояс от петли «ядро -> TUN -> ядро». Сервер с IPv6-адресом при
/// IPv4-only резолве давал пустой список, и его собственный трафик заворачивало
/// в туннель.
public func resolveIPs(_ host: String) -> [String] {
    // Литерал приводим к канону тем же путём, что и адреса от клиента, — то
    // есть строгим inet_pton, а не разбором строки.
    if let ip = normalizedIPAddress(host) { return [ip] }

    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                         ai_protocol: 0, ai_addrlen: 0,
                         ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &list) == 0, let head = list else { return [] }
    defer { freeaddrinfo(head) }

    var found = Set<String>()
    var info: UnsafeMutablePointer<addrinfo>? = head
    while let candidate = info {
        defer { info = candidate.pointee.ai_next }
        guard let sa = candidate.pointee.ai_addr else { continue }
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var addr = sin.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    found.insert(String(cString: buf))
                }
            }
        case AF_INET6:
            sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                var addr = sin6.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    found.insert(String(cString: buf))
                }
            }
        default:
            continue
        }
    }
    return found.sorted()
}
#endif
