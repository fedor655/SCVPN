import XCTest
@testable import SCVPNHelperKit

final class OutboxTests: XCTestCase {

    /// Пара сокетов: у одного конца читателя нет, поэтому буфер ядра
    /// заполняется и писатель Outbox встаёт — ровно тот случай, ради которого
    /// очередь и ограничена.
    private func makeOutbox(maxSize: Int) throws -> (out: Outbox, peer: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw HelperError("socketpair не удался")
        }
        // Забиваем буфер, чтобы писатель точно встал на первом же кадре:
        // иначе очередь разгребается быстрее, чем проверка успевает её
        // переполнить, и проверка зеленеет, ничего не проверив.
        var size: Int32 = 1024
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[1], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let out = Outbox(fd: fds[0], maxSize: maxSize, log: { _ in }).start()
        return (out, fds[1])
    }

    private func flood(_ out: Outbox, _ n: Int, log: Bool) {
        let filler = String(repeating: "я", count: 2048)
        for i in 0..<n {
            if log { out.sendLog(["log": "\(i) \(filler)"]) }
            else { out.send(["ok": false, "error": "\(i) \(filler)"]) }
        }
    }

    func test_drops_logs_instead_of_stalling() throws {
        let (out, peer) = try makeOutbox(maxSize: 4)
        defer { out.close(timeout: 0.2); close(peer) }
        flood(out, 200, log: true)
        XCTAssertLessThanOrEqual(out.pending, 4)
        XCTAssertGreaterThan(out.dropped, 0)
    }

    func test_never_drops_the_reply() throws {
        let (out, peer) = try makeOutbox(maxSize: 4)
        defer { out.close(timeout: 0.2); close(peer) }
        flood(out, 40, log: true)
        out.send(["ok": true, "running": true])
        // Ответу место освобождается за счёт самого старого лога, а не за счёт
        // самого ответа: потерянный ответ на start оставляет приложение в
        // убеждении, что туннеля нет, пока весь трафик идёт в туннель.
        XCTAssertTrue(out.snapshot().contains { $0["ok"] != nil })
    }

    func test_outbox_has_a_ceiling_even_for_replies() throws {
        let (out, peer) = try makeOutbox(maxSize: 4)
        defer { out.close(timeout: 0.2); close(peer) }
        flood(out, 200, log: false)
        XCTAssertLessThanOrEqual(out.pending, 16)
        XCTAssertTrue(out.isClosed, "переполнение обязано закрыть соединение")
    }

    func test_overflow_shuts_the_socket_down_so_the_reader_sees_eof() throws {
        let (out, peer) = try makeOutbox(maxSize: 4)
        defer { out.close(timeout: 0.2); close(peer) }
        flood(out, 200, log: false)
        XCTAssertTrue(out.isClosed)
        // shutdown, а не close: читатель получает EOF и уходит в свою уборку,
        // а уборка и есть dead-man's switch.
        var buf = [UInt8](repeating: 0, count: 1)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Вычитываем всё, что успело уйти, пока не упрёмся в EOF.
        var sawEOF = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let n = read(peer, &buf, 1)
            if n == 0 { sawEOF = true; break }
            if n < 0 { break }
        }
        XCTAssertTrue(sawEOF, "после переполнения читатель не получил EOF")
    }

    func test_frames_are_single_line_json() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let out = Outbox(fd: fds[0], maxSize: 16, log: { _ in }).start()
        defer { out.close(timeout: 0.5); close(fds[0]); close(fds[1]) }

        out.send(["ok": true, "error": "строка\nс переводом"])
        var chunk = [UInt8](repeating: 0, count: 4096)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let n = read(fds[1], &chunk, chunk.count)
        XCTAssertGreaterThan(n, 0)
        let text = String(decoding: chunk[0..<max(n, 0)], as: UTF8.self)
        // Ровно один перевод строки — тот, что разграничивает кадры. Перевод
        // внутри значения обязан уехать экранированным.
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, text)
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func test_writing_into_a_closed_socket_does_not_kill_the_process() throws {
        // Без SO_NOSIGPIPE запись в закрытую трубу убивает весь процесс
        // сигналом. Процесс здесь — root-овый демон, стерегущий sing-box:
        // клиент, закрывший соединение в неудачный момент, сносил бы демона, а
        // sing-box оставался бы сиротой с маршрутами. Проверка падает целиком
        // (сигнал, а не assert), если пояс снимут.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let out = Outbox(fd: fds[0], maxSize: 16, log: { _ in }).start()
        close(fds[1])
        for i in 0..<50 { out.send(["ok": false, "error": "\(i)"]) }
        Thread.sleep(forTimeInterval: 0.3)
        out.close(timeout: 0.5)
        close(fds[0])
    }

    func test_send_after_close_is_silent() throws {
        let (out, peer) = try makeOutbox(maxSize: 4)
        defer { close(peer) }
        out.close(timeout: 0.5)
        out.send(["ok": true])
        out.sendLog(["log": "поздно"])
        // Ни падения, ни роста очереди: соединение уже закончилось.
        XCTAssertTrue(out.isClosed)
    }
}
