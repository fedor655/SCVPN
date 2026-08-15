// Только macOS: демон, sing-box, системный прокси и дочерние процессы.
// На iOS ничего этого нет — там туннель поднимает NEPacketTunnelProvider.
#if os(macOS)
import Foundation

/// TUN-режим: весь трафик устройства идёт через VPN.
///
/// Xray работает от имени пользователя и слушает локальный SOCKS — именно он
/// делает TLS/Reality-рукопожатие с сервером, поэтому автоподбор отпечатка
/// остаётся в силе. sing-box поднимает utun, забирает весь трафик системы и
/// заворачивает его в этот SOCKS. Он требует root, поэтому запускает его демон.
///
/// Этот тип — тонкий клиент демона. Соединение держится открытым всё время
/// работы приложения: его обрыв демон читает как «приложение мертво» и снимает
/// туннель сам.
public final class Tun {
    private let lock = NSRecursiveLock()
    private var conn: HelperConnection?
    private var running = false
    private let socketPath: String

    public var onLog: (String) -> Void
    public var onState: (Bool) -> Void

    public init(socketPath: String = Paths.helperSocket,
                onLog: @escaping (String) -> Void = { _ in },
                onState: @escaping (Bool) -> Void = { _ in }) {
        self.socketPath = socketPath
        self.onLog = onLog
        self.onState = onState
    }

    /// Брошенный `Tun` закрывает своё соединение.
    ///
    /// Без этого туннель оставался бы поднятым навсегда: поток-читатель держит
    /// соединение живым, поэтому его собственный `deinit` не сработает, пока
    /// сокет открыт, а сокет не закроется, пока жив поток. Круг разрывается
    /// здесь. Команду `stop` не шлём и ответа не ждём — в `deinit` ждать по
    /// двенадцать секунд нельзя, да и незачем: обрыв соединения демон читает
    /// как «приложение мертво» и снимает туннель сам. Это ровно тот путь,
    /// ради которого dead-man's switch и написан.
    deinit {
        conn?.close()
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start(server: Server, socksPort: Int,
                      splitMode: SplitMode = .off, splitApps: [String] = [],
                      stack: Stack = .gvisor) throws {
        lock.lock(); defer { lock.unlock() }

        if conn != nil {
            // Прошлая сессия не закрыла своё соединение сама: onState(false)
            // уже пришёл (sing-box умер сам), а стоп не позвали. Без явного
            // закрытия второй start завёл бы ещё один сокет и поток поверх
            // висящего.
            _ = stop()
        }

        let ips = resolveIPs(server.address)
        if ips.isEmpty {
            onLog("[tun] не удалось определить IP сервера \(server.address), маршрут-исключение пуст")
        } else {
            onLog("[tun] обход для IP сервера: \(ips.joined(separator: ", "))")
        }
        if splitMode != .off && !splitApps.isEmpty {
            let what = splitMode == .exclude ? "мимо VPN" : "через VPN"
            onLog("[tun] раздельный туннель: \(what) — \(splitApps.joined(separator: ", "))")
        }

        let connection = try HelperConnection(socketPath: socketPath) { [onLog] s in
            onLog("[tun] " + s)
        }
        do {
            let reply = try connection.request([
                "cmd": "start",
                "socks_port": socksPort,
                "exclude_ips": ips,
                "split_mode": splitMode.rawValue,
                "split_apps": splitApps,
                "stack": stack.rawValue,
                "xray_path": Paths.xrayExe.resolvingSymlinksInPath().path,
            ], timeout: 60)
            guard reply["ok"] as? Bool == true else {
                throw HelperClientError((reply["error"] as? String) ?? "не удалось поднять TUN")
            }
        } catch {
            // Сюда попадает и таймаут, и обрыв, и честный отказ демона — всё
            // это уже ПОСЛЕ того, как демон мог поднять туннель. Не закрой мы
            // соединение здесь, туннель остался бы поднятым до тех пор, пока
            // до сокета не доберётся сборщик, то есть непредсказуемо.
            connection.close()
            throw error
        }

        conn = connection
        running = true
        onLog("[tun] sing-box запущен (поднимаю utun-адаптер)…")
        onState(true)

        // Соединение остаётся открытым: демон читает его обрыв как «приложение
        // мертво». С этого момента и до stop() читает сокет только этот поток.
        // Соединение потоку передаём аргументом, а не читаем из поля: по нему
        // он и узнаёт, его ли ещё очередь докладывать о состоянии.
        let thread = Thread { [weak self] in self?.readLogs(connection) }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func readLogs(_ connection: HelperConnection) {
        /// Всё ещё ли `conn` — то соединение, которое читает этот поток.
        ///
        /// Нет — значит либо его закрыл `stop()` (он обнуляет поле первой
        /// строкой и сам докладывает, чем всё кончилось), либо поверх уже
        /// поднята новая сессия. В обоих случаях рассказывать свою версию
        /// событий не наше дело.
        ///
        /// Сверка по **идентичности объекта**, а не по флагу «идёт остановка»:
        /// флаг пришлось бы снимать, и поток, просыпающийся от закрытия не
        /// мгновенно, успел бы увидеть его снятым.
        func mine() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return conn === connection
        }

        connection.stream { msg in
            guard let text = msg["log"] as? String else {
                // Не лог — значит ответ на команду. Свой ответ читает сам
                // только start(), и он успевает до запуска этого потока; всё,
                // что доходит сюда, ждёт stop().
                connection.putReply(msg)
                return
            }
            onLog("[tun] " + text)
            // Демон снял sing-box сам — упал ли тот или его забрал другой
            // клиент, — а соединение при этом НЕ рвёт: обрыв связи демон читает
            // как «приложение мертво», а тут приложение живо, просто без
            // туннеля. Без этой проверки Tun продолжал бы считать себя
            // подключённым до следующего действия пользователя.
            if text.hasPrefix("sing-box завершился") {
                lock.lock()
                let isMine = conn === connection, wasRunning = running
                if isMine && wasRunning { running = false }
                lock.unlock()
                if isMine && wasRunning { onState(false) }
            }
        }

        guard mine() else { return }
        lock.lock()
        let wasRunning = running
        if wasRunning { running = false }
        lock.unlock()
        if wasRunning {
            onLog("[tun] системный компонент закрыл соединение")
            onState(false)
        }
    }

    /// Снять туннель. `true` — снят; `false` — демон честно ответил, что нет.
    ///
    /// Ответ демона на `stop` правдив по построению: он смотрит на живой
    /// процесс, а не рапортует вслепую. Прочитать его обязательно: sing-box
    /// имеет право пережить и SIGTERM, и SIGKILL — и тогда utun поднят,
    /// маршруты держатся, а «Отключено» на экране это ровно та ложь о
    /// состоянии, ради ухода от которой правду и добывали.
    @discardableResult
    public func stop() -> Bool {
        lock.lock()
        let connection = conn
        conn = nil
        let wasRunning = running
        lock.unlock()

        guard let connection else {
            // Соединения нет, а туннель мы всё ещё считаем поднятым — так
            // бывает ровно после неудачного stop() ниже: sing-box пережил
            // остановку, соединение закрыто, попросить демона больше нечем.
            // Сказать «снят» здесь значило бы соврать повторно.
            return !wasRunning
        }

        // С этой секунды поле уже не то соединение, которое читает поток логов,
        // и поток по этому признаку замолкает, оставляя доклад за нами.
        onLog("[tun] останавливаю туннель (маршруты вернутся сами)…")
        var reply: [String: Any]?
        // request() здесь не годится: сокет с момента start() читает поток
        // логов, и второй читатель забирал бы строки непредсказуемо — на этом
        // ответ на stop когда-то и терялся, подвешивая stop() до таймаута.
        // Команду шлём отсюда, а ответ забираем у единственного читателя.
        connection.drainReplies()
        do {
            try connection.send(["cmd": "stop"])
            reply = connection.awaitReply(timeout: stopReplyTimeoutSec)
            if reply == nil {
                onLog("[tun] системный компонент не ответил на команду остановки")
            }
        } catch {
            onLog("[tun] не удалось отправить команду остановки: \(error)")
        }
        // Даже если команда не дошла — демон увидит обрыв и снимет туннель сам.
        connection.close()

        if reply?["running"] as? Bool == true {
            onLog("[tun] ТРЕВОГА: sing-box пережил остановку — туннель ещё держит маршруты")
            lock.lock(); running = true; lock.unlock()
            return false
        }

        // Проверка не лишняя: туннель мог отвалиться сам ещё до stop() — тогда
        // поток логов уже доложил об этом, и повторять незачем.
        if wasRunning {
            lock.lock(); running = false; lock.unlock()
            onState(false)
        }
        return true
    }
}

/// Разовая команда демону на отдельном соединении.
func askDaemon(_ cmd: String, socketPath: String = Paths.helperSocket,
               say: @escaping (String) -> Void, what: String) throws -> [String: Any] {
    let conn = try HelperConnection(socketPath: socketPath, onLog: say)
    defer { conn.close() }
    let reply = try conn.request(["cmd": cmd])
    guard reply["ok"] as? Bool == true else {
        throw HelperClientError((reply["error"] as? String) ?? what)
    }
    return reply
}

/// Попросить демона скачать sing-box себе. Вернуть версию.
public func installSingboxViaHelper(socketPath: String = Paths.helperSocket,
                                    progress: @escaping (String) -> Void = { _ in }) throws -> String {
    let reply = try askDaemon("install_singbox", socketPath: socketPath,
                              say: progress, what: "не удалось установить sing-box")
    return reply["version"] as? String ?? "?"
}

/// Попросить демона удалить sing-box у себя. `true` — файл был и удалён.
///
/// Удаляет тоже демон: файл лежит в его root-овой папке, и пользователю она
/// доступна только на чтение. Демон откажет, пока туннель поднят.
public func removeSingboxViaHelper(socketPath: String = Paths.helperSocket,
                                   progress: @escaping (String) -> Void = { _ in }) throws -> Bool {
    let reply = try askDaemon("remove_singbox", socketPath: socketPath,
                              say: progress, what: "не удалось удалить sing-box")
    return reply["removed"] as? Bool ?? false
}
#endif
