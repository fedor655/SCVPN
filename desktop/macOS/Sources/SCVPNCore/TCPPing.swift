import Foundation

/// Найти свободный TCP-порт на `127.0.0.1`, начиная с `preferred`.
///
/// Нужно, чтобы не конфликтовать с другими VPN-клиентами: Happ держит
/// 10808/10809, и без этого поиска ядро молча не поднялось бы.
public func findFreePort(preferred: Int) -> Int {
    for port in preferred..<(preferred + 100) where canBind(port) {
        return port
    }
    // Все сто заняты — берём любой эфемерный, лишь бы работало.
    return bindEphemeral() ?? preferred
}

private func canBind(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 }
    }
}

private func bindEphemeral() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 }
    }
    guard bound else { return nil }
    var out = sockaddr_in()
    let got = withUnsafeMutablePointer(to: &out) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) == 0 }
    }
    return got ? Int(UInt16(bigEndian: out.sin_port)) : nil
}

/// Задержка до сервера в миллисекундах, или `nil`, если порт недоступен.
///
/// Это не ICMP-пинг, а время установки TCP-соединения: для VPN оно полезнее,
/// потому что меряет доступность именно нужного порта.
///
/// Неблокирующий `connect` плюс `poll` — иначе таймаут был бы не наш, а
/// системный (на macOS около минуты), и «сервер не отвечает» приходило бы через
/// минуту вместо трёх секунд.
public func tcpPing(host: String, port: Int, timeout: TimeInterval = 3.0) -> Int? {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                         ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
                         ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &list) == 0, let head = list else {
        return nil
    }
    defer { freeaddrinfo(head) }

    var info: UnsafeMutablePointer<addrinfo>? = head
    while let candidate = info {
        defer { info = candidate.pointee.ai_next }
        if let ms = connectMeasuring(candidate.pointee, timeout: timeout) { return ms }
    }
    return nil
}

private func connectMeasuring(_ info: addrinfo, timeout: TimeInterval) -> Int? {
    let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }

    let start = DispatchTime.now()
    let rc = connect(fd, info.ai_addr, info.ai_addrlen)
    if rc != 0 {
        guard errno == EINPROGRESS else { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        guard ready > 0 else { return nil }
        // POLLOUT приходит и на отказ соединения — правду говорит SO_ERROR.
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
    }
    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return Int(ns / 1_000_000)
}
