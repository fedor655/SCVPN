import Foundation
import SCVPNCore

/// Соединение клиента как объект.
///
/// Идентичность обязана быть **ссылочной**: номера дескрипторов
/// переиспользуются, и закрывшееся соединение с fd 7 сравнялось бы с новым,
/// получившим тот же 7, — чужой обрыв снёс бы живой туннель. Python сравнивал
/// объекты сокетов ровно по этой причине.
public final class ClientHandle {
    public let fd: Int32
    public init(fd: Int32) { self.fd = fd }
}

/// Демон не смог сделать то, о чём попросили.
public struct HelperError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

/// Один живой sing-box и его конфиг. Останавливается при обрыве клиента.
///
/// `owner` — соединение, которое подняло текущий туннель. Раньше клиент был
/// ровно один, и обслуживающий поток снимал туннель по факту **любого** обрыва
/// — это было верно, пока у демона не завелись короткоживущие соединения без
/// своего туннеля (`install_singbox` открывает отдельное соединение на один
/// запрос и закрывает его). Без `owner` обрыв такого постороннего соединения
/// сносил бы **чужой** активный туннель.
public final class Supervisor {
    private let env: HelperEnv
    // Клиентов может оказаться больше одного (соединений никто не считает), а
    // sing-box один на всех. Под замком start и stop не переплетаются, и
    // процесс не остаётся без хозяина между «создал» и «записал в себя».
    // Рекурсивный — start зовёт stop под тем же замком.
    private let lock = NSRecursiveLock()
    private var proc: Process?
    private var exited: DispatchSemaphore?

    public private(set) var owner: ClientHandle?

    public init(env: HelperEnv) {
        self.env = env
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let proc else { return false }
        return proc.isRunning
    }

    public func start(_ params: SingboxParams, xrayPath: String,
                      onLog: @escaping (String) -> Void, owner: ClientHandle?) throws {
        lock.lock(); defer { lock.unlock() }

        // Двух sing-box рядом быть не должно: они подерутся за default route.
        // Прежнего снимаем, осиротевшего от прошлого демона подметаем, и если
        // хоть один остался жив — не поднимаем ничего.
        if isRunning { stop() }
        if isRunning {
            throw HelperError("прежний sing-box не снялся, второй поверх него не поднимаю")
        }
        if !killStaleSingbox(env) {
            throw HelperError("осиротевший sing-box держит маршруты, сначала снимите его")
        }

        let exe = env.singboxExe
        try env.checkBinary(exe)

        try FileManager.default.createDirectory(at: env.runDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Права выставляем и отдельно: если папка уже была, createDirectory
        // атрибуты не применяет.
        chmod(env.runDir.path, 0o700)

        let cfg = buildSingboxConfig(params, xrayPath: xrayPath)
        let data = try JSONSerialization.data(withJSONObject: cfg,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: env.configPath, options: .atomic)
        chmod(env.configPath.path, 0o600)

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["run", "-c", env.configPath.path]
        proc.currentDirectoryURL = env.binDir
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }

        try proc.run()

        // owner выставляем вплотную к запуску, ДО первой записи в лог: лог
        // пишется в stderr, который под launchd — файл, и запись может
        // отказать (ENOSPC, EIO, сломанная труба). Стой лог между запуском и
        // owner и упади он — получилось бы состояние, которого быть не должно:
        // процесс поднят, isRunning уже true, а owner ещё nil, и обработчик
        // обрыва не признал бы в соединении владельца. Зазор обязан быть пуст.
        self.proc = proc
        self.exited = sem
        self.owner = owner

        env.log("sing-box запущен, PID \(proc.processIdentifier)")

        // Колбэк передаём аргументом, а не читаем из поля: после рестарта
        // «sing-box завершился» от старого процесса ушло бы новому клиенту,
        // как будто это про его туннель.
        let readerEnv = env
        // Отдельный поток с read(2), а не readabilityHandler: тот приходит на
        // общую очередь и путает порядок при остановке.
        let thread = Thread {
            pumpLines(from: pipe.fileHandleForReading, onLine: onLog)
            proc.waitUntilExit()
            let code = proc.terminationStatus
            onLog("sing-box завершился (код \(code))")
            readerEnv.log("sing-box завершился (код \(code))")
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Снять sing-box и отпустить ручку только после подтверждённой смерти.
    ///
    /// Ручку не отпускаем, пока смерть не подтверждена. Если процесс не умер
    /// (непрерываемый сон для TUN-процесса правдоподобен), обнулять `proc`
    /// нельзя: `isRunning` соврал бы `false`, обработчики обрыва прошли бы
    /// мимо, а следующий `start` поднял бы второй рядом с первым.
    public func stop() {
        lock.lock(); defer { lock.unlock() }

        guard let proc, let exited else { return }
        if !proc.isRunning {
            self.proc = nil
            self.exited = nil
            self.owner = nil
            return
        }

        env.log("останавливаю sing-box (маршруты вернутся сами)")
        proc.terminate()
        if exited.wait(timeout: .now() + env.stopGrace) == .timedOut {
            env.log("sing-box не ушёл по SIGTERM — добиваю")
            // У Process прямого SIGKILL нет.
            kill(proc.processIdentifier, SIGKILL)
            if exited.wait(timeout: .now() + env.killGrace) == .timedOut {
                env.log("ТРЕВОГА: sing-box PID \(proc.processIdentifier) пережил SIGKILL, "
                        + "туннель остаётся поднятым — ручку не отпускаю")
                // Семафор мог быть израсходован ожиданиями выше — возвращаем
                // его в исходное состояние не мы, а сам terminationHandler,
                // когда процесс всё-таки умрёт.
                return
            }
        }

        self.proc = nil
        self.exited = nil
        self.owner = nil
    }
}

/// Читать дескриптор построчно до EOF.
///
/// Через `read(2)`, а не `readLine`/`availableData` в цикле Foundation: нужен
/// предсказуемый порядок строк и никакой диспетчеризации на чужие очереди.
func pumpLines(from handle: FileHandle, onLine: (String) -> Void) {
    let fd = handle.fileDescriptor
    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[0..<idx], as: UTF8.self)
            buffer.removeSubrange(0...idx)
            if !line.isEmpty { onLine(line) }
        }
    }
    if !buffer.isEmpty {
        let line = String(decoding: buffer, as: UTF8.self)
        if !line.isEmpty { onLine(line) }
    }
}
