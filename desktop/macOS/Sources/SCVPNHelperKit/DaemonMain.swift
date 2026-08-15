import Foundation

/// Сигналы, по которым демон уходит сам, сняв туннель.
///
/// `SIGHUP` здесь не для красоты: демона запускают и руками, и закрытое окно
/// терминала не должно оставлять root-овый sing-box с маршрутами.
let exitSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]

/// Открыть слушающий unix-сокет по правилам протокола.
///
/// Права `0660` и владелец `root:admin`: обычный пользователь не должен уметь
/// поднять туннель и подсунуть свои правила маршрутизации.
func listenOnSocket(_ env: HelperEnv) throws -> Int32 {
    unlink(env.socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw HelperError("не смог создать сокет: \(String(cString: strerror(errno)))")
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(env.socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        throw HelperError("путь сокета длиннее, чем помещается в sockaddr_un: \(env.socketPath)")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    guard bound == 0 else {
        close(fd)
        throw HelperError("не смог привязать \(env.socketPath): \(String(cString: strerror(errno)))")
    }

    if let group = getgrnam(adminGroup) {
        chown(env.socketPath, 0, group.pointee.gr_gid)
    } else {
        env.log("нет группы \(adminGroup) — сокет остаётся с группой по умолчанию")
    }
    chmod(env.socketPath, 0o660)

    guard listen(fd, 4) == 0 else {
        close(fd)
        throw HelperError("не смог слушать \(env.socketPath): \(String(cString: strerror(errno)))")
    }
    return fd
}

/// Принимать клиентов, пока не попросят уйти.
func serveForever(_ srv: Int32, _ sup: Supervisor, _ env: HelperEnv) {
    // Клиентов обслуживаем по одному в потоке, без ограничения их числа.
    // Приложение открывает ровно одно соединение; если понадобится защита от
    // заваливания, ставить семафор на число живых потоков.
    while true {
        let fd = accept(srv, nil, nil)
        if fd < 0 {
            if errno == EINTR { continue }
            return
        }
        let t = Thread { serveClient(fd: fd, sup: sup, env: env) }
        t.stackSize = 512 * 1024
        t.start()
    }
}

/// Точка входа демона.
///
/// Порядок обязан остаться прежним:
///  1. Не root — уйти с кодом 1.
///  2. **Замок захватывается до любой разрушительной операции.** Дальше идут
///     снятие чужого sing-box и перехват сокета; `killStaleSingbox` бьёт по
///     всей командной строке, не различая, чей это процесс, — второй демон
///     снёс бы рабочий туннель первого.
///  3. Установить обработчики сигналов.
///  4. `killStaleSingbox`.
///  5. Открыть сокет.
///  6. Accept-цикл; на выходе — снять туннель и убрать сокет.
public func daemonMain(_ env: HelperEnv) -> Never {
    // Под root — только продакшен-окружение; тестовая лазейка в продакшене это
    // дыра. Проверка живёт в HelperEnv.fromEnvironment, здесь только root.
    guard geteuid() == 0 || ProcessInfo.processInfo.environment["SCVPN_HELPER_SOCKET"] != nil else {
        env.log("демон обязан работать от root")
        exit(1)
    }

    // Пояс поверх SO_NOSIGPIPE на каждом сокете: любая запись в закрытую трубу
    // иначе убивает демона сигналом, а вместе с ним теряется надзор за
    // sing-box. Ставится до открытия чего бы то ни было.
    signal(SIGPIPE, SIG_IGN)

    // До этой черты — только чтение. Дальше разрушительные операции, поэтому
    // единственность проверяем первым делом, раньше killStaleSingbox.
    let lock: SingletonLock
    do {
        lock = try SingletonLock(path: env.lockPath)
    } catch {
        env.log("\(error)")
        exit(1)
    }

    let sup = Supervisor(env: env)
    installSignalHandlers(sup, env)

    if !killStaleSingbox(env) {
        env.log("предыдущий sing-box снять не удалось — туннель поднимать не буду")
    }

    let srv: Int32
    do {
        srv = try listenOnSocket(env)
    } catch {
        env.log("\(error)")
        exit(1)
    }
    env.log("слушаю \(env.socketPath)")

    // Accept-цикл живёт на отдельном потоке, главный отдан диспетчеру:
    // источники сигналов иначе не сработают.
    let accepting = Thread {
        serveForever(srv, sup, env)
        sup.stop()
        close(srv)
        unlink(env.socketPath)
    }
    accepting.start()

    // Замок держим живым до конца процесса: попади дескриптор только в
    // локальную переменную, ARC закрыл бы его вместе с блокировкой.
    withExtendedLifetime(lock) {
        dispatchMain()
    }
}

private let signalQueue = DispatchQueue(label: "com.scvpn.helper.signals")
private var signalSources: [DispatchSourceSignal] = []

/// Перехватить сигналы, по которым иначе умерли бы молча, мимо уборки.
///
/// Обработчики сигналов в Swift писать нельзя: async-signal-safety не
/// соблюсти, а снятие туннеля — это Process, замки и ожидания. Поэтому сигнал
/// глушится на уровне POSIX, а работу делает `DispatchSourceSignal` на обычной
/// очереди.
///
/// От SIGKILL защиты нет — её роль играет подметание при следующем старте.
func installSignalHandlers(_ sup: Supervisor, _ env: HelperEnv) {
    for sig in exitSignals {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        src.setEventHandler {
            // Повторные сигналы заглушаются первым делом. Без этого второй
            // SIGTERM, пришедший пока идёт снятие, обрывал бы его на середине:
            // демон уходил бы с кодом 0, а sing-box оставался бы жив с
            // маршрутами.
            signalSources.forEach { $0.cancel() }
            env.log("сигнал \(sig) — снимаю туннель и выхожу")
            sup.stop()
            unlink(env.socketPath)
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
}
