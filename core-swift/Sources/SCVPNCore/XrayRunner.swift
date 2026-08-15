// Только macOS: демон, sing-box, системный прокси и дочерние процессы.
// На iOS ничего этого нет — там туннель поднимает NEPacketTunnelProvider.
#if os(macOS)
import Foundation

/// Запуск и остановка ядра Xray.
///
/// Пишет конфиг в `xray_running.json` — файл можно открыть и посмотреть,
/// запускает ядро дочерним процессом, читает его вывод отдельным потоком и
/// отдаёт строки колбэком.
///
/// PID уходит на диск: если приложение закроется аварийно, ядро останется
/// работать само по себе, и следующий запуск обязан его найти и снять.
public final class XrayRunner {
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

    public func start(_ config: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        if isRunning { stop() }

        let exe = Paths.xrayExe
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw ValidationError("""
                Не найдено ядро Xray: \(exe.path)
                Скачай его кнопкой в приложении.
                """)
        }

        Paths.ensureDirs()
        let cfgPath = Paths.xrayConfigFile
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: cfgPath, options: .atomic)

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["run", "-c", cfgPath.path]
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
        try? Data("\(proc.processIdentifier)".utf8).write(to: Paths.xrayPIDFile)

        onLog("[core] запуск: \(exe.lastPathComponent) run -c \(cfgPath.lastPathComponent)")
        onState(true)

        let onLog = self.onLog
        let onState = self.onState
        let reader = Thread {
            pumpXrayLines(from: pipe.fileHandleForReading, onLine: onLog)
            proc.waitUntilExit()
            onLog("[core] процесс завершился (код \(proc.terminationStatus))")
            onState(false)
        }
        reader.stackSize = 512 * 1024
        reader.start()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let proc else { return }
        if proc.isRunning {
            onLog("[core] остановка ядра…")
            proc.terminate()
            if exited?.wait(timeout: .now() + 5) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        self.proc = nil
        self.exited = nil
        try? FileManager.default.removeItem(at: Paths.xrayPIDFile)
        onState(false)
    }

    /// Снять ядро, оставшееся от аварийно закрытого приложения.
    ///
    /// Проверяем не только сам факт живого PID, но и что это действительно наш
    /// xray: номера переиспользуются, и слепой `kill` по записи из файла рано
    /// или поздно попал бы в чужой процесс.
    @discardableResult
    public static func cleanupStray() -> Bool {
        guard let text = try? String(contentsOf: Paths.xrayPIDFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        defer { try? FileManager.default.removeItem(at: Paths.xrayPIDFile) }

        guard processPath(pid) == Paths.xrayExe.resolvingSymlinksInPath().path else {
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

/// Абсолютный путь исполняемого файла процесса, или `nil`, если его нет.
func processPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(cString: buf)
}

func pumpXrayLines(from handle: FileHandle, onLine: (String) -> Void) {
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
#endif
