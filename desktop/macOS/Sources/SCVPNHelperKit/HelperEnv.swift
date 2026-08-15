import Foundation

/// Результат запуска внешнего инструмента. `nil` вместо него означает, что
/// инструмент не отработал вовсе, — и это не то же самое, что «ничего не нашёл».
public struct ProcResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Сколько ждать ухода sing-box: сначала по SIGTERM (он разбирает маршруты
/// сам), потом по SIGKILL. В `HelperEnv`, а не глобальными константами, чтобы
/// проверки не ждали по семь секунд — подменить глобальную константу в Swift
/// нельзя, а без подмены ни одна проверка демона не пишется.
public let productionStopGrace: TimeInterval = 7
public let productionKillGrace: TimeInterval = 3
public let productionSweepGrace: TimeInterval = 3

/// Потолки на размер запроса. `validate` ограничивает длину каждого имени
/// приложения, но не число элементов в списках: 200 000 имён — это конфиг на
/// десяток мегабайт, который root молча запишет на диск.
public let maxSplitApps = 256
public let maxExcludeIPs = 1024
/// 1 МиБ на строку запроса — с потолками выше с запасом.
public let maxLine = 1 << 20
/// Сколько сообщений держим для клиента, который перестал читать сокет.
public let outboxLimit = 256

/// Группа, которой открыт сокет. Обычные пользователи в неё не входят.
public let adminGroup = "admin"

public let singboxReleasesAPI = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"

/// Вся конфигурация демона одним значением.
///
/// Почему не модульные константы, как в Python. Проверки демона подменяли
/// `daemon.BIN_DIR`, `daemon.RUN_DIR`, `daemon.check_binary`,
/// `daemon.STOP_GRACE_SEC`. В Swift глобальную константу подменить нельзя,
/// поэтому конфигурация передаётся аргументом. Это не украшение: без этого ни
/// одна из проверок демона не пишется.
public struct HelperEnv {
    public var binDir: URL
    public var runDir: URL
    public var socketPath: String
    public var lockPath: String
    public var stopGrace: TimeInterval
    public var killGrace: TimeInterval
    public var sweepGrace: TimeInterval
    public var checkBinary: (URL) throws -> Void
    public var log: (String) -> Void
    /// pgrep/pkill полем, а не вызовом напрямую: проверка «не смог посмотреть
    /// = сирота жива» должна уметь подсунуть отказ инструмента.
    public var procTool: ([String]) -> ProcResult?

    public var singboxExe: URL { binDir.appendingPathComponent("sing-box") }
    public var configPath: URL { runDir.appendingPathComponent("singbox.json") }

    public init(binDir: URL, runDir: URL, socketPath: String, lockPath: String,
                stopGrace: TimeInterval, killGrace: TimeInterval, sweepGrace: TimeInterval,
                checkBinary: @escaping (URL) throws -> Void,
                log: @escaping (String) -> Void,
                procTool: @escaping ([String]) -> ProcResult?) {
        self.binDir = binDir
        self.runDir = runDir
        self.socketPath = socketPath
        self.lockPath = lockPath
        self.stopGrace = stopGrace
        self.killGrace = killGrace
        self.sweepGrace = sweepGrace
        self.checkBinary = checkBinary
        self.log = log
        self.procTool = procTool
    }
}

/// В stderr — launchd сложит его в StandardErrorPath.
public func helperLog(_ msg: String) {
    FileHandle.standardError.write(Data("[helper] \(msg)\n".utf8))
}

extension HelperEnv {
    public static var production: HelperEnv {
        let helperDir = URL(fileURLWithPath: "/Library/Application Support/SCVPN")
        let binDir = helperDir.appendingPathComponent("bin")
        return HelperEnv(
            binDir: binDir,
            runDir: helperDir.appendingPathComponent("run"),
            socketPath: "/var/run/scvpn-helper.sock",
            lockPath: "/var/run/scvpn-helper.lock",
            stopGrace: productionStopGrace,
            killGrace: productionKillGrace,
            sweepGrace: productionSweepGrace,
            checkBinary: { try SCVPNHelperKit.checkBinary($0, binDir: binDir) },
            log: helperLog,
            procTool: runProcTool
        )
    }

    /// Тестовое окружение поверх временной папки.
    ///
    /// `stopGrace` и `sweepGrace` — по секунде: иначе каждая проверка снятия
    /// ждала бы по семь секунд, и полный прогон стал бы тем, что не гоняют.
    public static func testing(tmp: URL) -> HelperEnv {
        let binDir = tmp.appendingPathComponent("bin")
        return HelperEnv(
            binDir: binDir,
            runDir: tmp.appendingPathComponent("run"),
            socketPath: tmp.appendingPathComponent("sock").path,
            lockPath: tmp.appendingPathComponent("lock").path,
            stopGrace: 1,
            killGrace: 1,
            sweepGrace: 1,
            // Поддельный sing-box лежит в пользовательской папке и root'у не
            // принадлежит — настоящая проверка отвергла бы его первой же строкой.
            checkBinary: { _ in },
            log: helperLog,
            procTool: runProcTool
        )
    }

    /// Окружение для запущенного демона.
    ///
    /// Под root переменные окружения игнорируются целиком: тестовая лазейка в
    /// продакшене — это дыра, через которую любой admin подсунул бы демону
    /// свою папку бинарников.
    public static func fromEnvironment() -> HelperEnv {
        var env = HelperEnv.production
        guard geteuid() != 0 else { return env }

        let e = ProcessInfo.processInfo.environment
        if let v = e["SCVPN_HELPER_BIN_DIR"] { env.binDir = URL(fileURLWithPath: v) }
        if let v = e["SCVPN_HELPER_RUN_DIR"] { env.runDir = URL(fileURLWithPath: v) }
        if let v = e["SCVPN_HELPER_SOCKET"] { env.socketPath = v }
        if let v = e["SCVPN_HELPER_LOCK"] { env.lockPath = v }
        if let v = e["SCVPN_HELPER_STOP_GRACE"], let d = Double(v) { env.stopGrace = d }
        if let v = e["SCVPN_HELPER_KILL_GRACE"], let d = Double(v) { env.killGrace = d }
        if let v = e["SCVPN_HELPER_SWEEP_GRACE"], let d = Double(v) { env.sweepGrace = d }
        if e["SCVPN_HELPER_SKIP_BINARY_CHECK"] != nil {
            env.checkBinary = { _ in }
        } else {
            let binDir = env.binDir
            env.checkBinary = { try SCVPNHelperKit.checkBinary($0, binDir: binDir) }
        }
        return env
    }
}

/// Запустить pgrep/pkill. `nil` — инструмент не отработал, ответа нет.
public func runProcTool(_ args: [String]) -> ProcResult? {
    guard let first = args.first else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: first)
    proc.arguments = Array(args.dropFirst())
    let out = Pipe(), err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do {
        try proc.run()
    } catch {
        helperLog("не смог выполнить \(first): \(error)")
        return nil
    }
    // Читаем до EOF раньше waitUntilExit: на полной трубе процесс встал бы
    // насмерть, а мы ждали бы его ухода.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let result = ProcResult(status: proc.terminationStatus,
                            stdout: String(decoding: outData, as: UTF8.self),
                            stderr: String(decoding: errData, as: UTF8.self))
    // 0 — нашлось, 1 — никого не нашлось. Всё остальное (2 — кривой шаблон,
    // 3 — внутренняя ошибка) молчать нельзя: так защита от сироты погаснет
    // незаметно, а узнаем мы об этом по пропавшему интернету.
    if result.status != 0 && result.status != 1 {
        helperLog("\(first) вернул \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return result
}
