// Только macOS: дочерние процессы. На iOS туннель поднимает
// NEPacketTunnelProvider, и запускать там нечего.
#if os(macOS)
import Foundation

/// Запуск и остановка `scvpn-awg` — туннеля AmneziaWG.
///
/// Зачем отдельный процесс, а не outbound Xray: ядро Xray умеет обычный
/// WireGuard, но не умеет обфускацию Amnezia (`Jc`, `S1…S4`, `H1…H4`), а без
/// неё сервер с подменёнными заголовками не отвечает вовсе. `scvpn-awg` собран
/// из официального `amneziawg-go` и отдаёт туннель локальным SOCKS — тем же
/// интерфейсом, каким Xray отдаёт свой. Поэтому маршруты, DNS, TUN и
/// раздельное туннелирование остаются прежними, а вся разница в одном
/// outbound.
///
/// Повторяет форму `XrayRunner` намеренно: два процесса живут по одним
/// правилам (pid на диске, чтение вывода потоком, снятие осиротевшего), и
/// расхождение здесь стоило бы висящего туннеля после аварийного закрытия.
public final class AWGRunner {
    private let lock = NSRecursiveLock()
    private var proc: Process?
    private var exited: DispatchSemaphore?

    public var onLog: (String) -> Void
    public var onState: (Bool) -> Void

    public init(onLog: @escaping (String) -> Void = { _ in },
                onState: @escaping (Bool) -> Void = { _ in }) {
        self.onLog = onLog
        self.onState = onState
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return proc?.isRunning ?? false
    }

    /// Признак готовности в выводе процесса. Совпадает со строкой, которую
    /// печатает `awg/main.go`; менять только вместе с ней.
    static let readyMark = "[awg] готов:"

    /// Поднять туннель и дождаться готовности.
    ///
    /// Ждём именно строку, а не «процесс жив»: Xray, запущенный раньше времени,
    /// упёрся бы в закрытый порт и молча не работал, а пользователь видел бы
    /// «подключено».
    public func start(server: Server, socksPort: Int, timeout: TimeInterval = 10) throws {
        lock.lock(); defer { lock.unlock() }
        if isRunning { stop() }

        let exe = Paths.awgExe
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw ValidationError("""
                Не найден туннель AmneziaWG: \(exe.path)
                Собери его из awg/ или скачай кнопкой в приложении.
                """)
        }

        Paths.ensureDirs()
        let cfgPath = Paths.awgConfigFile
        // Права до записи, а не после: между созданием файла и chmod приватный
        // ключ иначе успел бы полежать читаемым для всех.
        FileManager.default.createFile(atPath: cfgPath.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        try Data(wireGuardConfText(server).utf8).write(to: cfgPath, options: .atomic)
        // .atomic пишет во временный файл и переименовывает, теряя права —
        // возвращаем их обратно.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: cfgPath.path)

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["-config", cfgPath.path, "-socks", "127.0.0.1:\(socksPort)"]
        proc.currentDirectoryURL = Paths.binDir
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        try proc.run()

        self.proc = proc
        self.exited = sem
        try? Data("\(proc.processIdentifier)".utf8).write(to: Paths.awgPIDFile)
        onLog("[awg] запуск: туннель на 127.0.0.1:\(socksPort)")
        onState(true)

        let ready = DispatchSemaphore(value: 0)
        let onLog = self.onLog
        let onState = self.onState
        let reader = Thread {
            var seen = false
            pumpXrayLines(from: pipe.fileHandleForReading) { line in
                onLog(line)
                if !seen, line.contains(AWGRunner.readyMark) {
                    seen = true
                    ready.signal()
                }
            }
            proc.waitUntilExit()
            onLog("[awg] процесс завершился (код \(proc.terminationStatus))")
            onState(false)
            // Разбудить ожидание, если процесс умер, не дойдя до готовности:
            // иначе подключение висело бы весь таймаут на уже мёртвом туннеле.
            ready.signal()
        }
        reader.stackSize = 512 * 1024
        reader.start()

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            stop()
            throw ValidationError("Туннель AmneziaWG не поднялся за \(Int(timeout)) с")
        }
        if !proc.isRunning {
            stop()
            throw ValidationError("Туннель AmneziaWG не запустился — смотри лог")
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let proc else { return }
        if proc.isRunning {
            onLog("[awg] остановка туннеля…")
            proc.terminate()
            if exited?.wait(timeout: .now() + 5) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        self.proc = nil
        self.exited = nil
        try? FileManager.default.removeItem(at: Paths.awgPIDFile)
        // Конфиг с приватным ключом не нужен между сеансами.
        try? FileManager.default.removeItem(at: Paths.awgConfigFile)
        onState(false)
    }

    /// Снять туннель, оставшийся от аварийно закрытого приложения.
    ///
    /// Путь бинарника сверяем по той же причине, что и у Xray: номера PID
    /// переиспользуются, и слепой `kill` рано или поздно попал бы в чужой
    /// процесс.
    @discardableResult
    public static func cleanupStray() -> Bool {
        guard let text = try? String(contentsOf: Paths.awgPIDFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        defer {
            try? FileManager.default.removeItem(at: Paths.awgPIDFile)
            try? FileManager.default.removeItem(at: Paths.awgConfigFile)
        }

        guard processPath(pid) == Paths.awgExe.resolvingSymlinksInPath().path else {
            return false
        }
        kill(pid, SIGTERM)
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
        return true
    }
}
#endif
