import Foundation
import XCTest
@testable import SCVPNHelperKit

/// Временный «демон» со своими папками и поддельным sing-box.
///
/// Главное свойство демона — снимать sing-box, когда клиент умер, — нельзя
/// проверить, разглядывая чистые функции. Поэтому стенд поднимает настоящий
/// сокет, настоящие потоки и настоящий процесс, но без root: `binDir` и
/// `runDir` — временная папка, `checkBinary` заглушён (его проверяют отдельно),
/// а вместо sing-box — скрипт, который спит.
final class Stand {

    /// Три поддельных sing-box.
    ///
    /// Метка готовности не для красоты: появление PID в pgrep ещё не значит,
    /// что оболочка успела выполнить `trap`. Ударив SIGTERM в этот зазор,
    /// «упрямый» sing-box умрёт как миленький, и проверка позеленеет, ничего не
    /// проверив. В метку кладём PID — так метка от прошлого запуска не сойдёт
    /// за готовность нового.
    ///
    /// Спим короткими интервалами, а не одним `sleep 300`: убитая оболочка не
    /// должна оставлять пятиминутного сироту, которого чистящий pkill не ловит.
    enum Script {
        case normal
        /// Игнорирует SIGTERM, как повёл бы себя зависший sing-box.
        case stubborn
        /// Умирает сам сразу после старта — падение sing-box или снятие его
        /// кем-то ещё. Соединение при этом демон не рвёт.
        case crashing

        func source(ready: String) -> String {
            switch self {
            case .normal:
                return "#!/bin/sh\necho $$ > \(ready)\nwhile :; do sleep 1; done\n"
            case .stubborn:
                return "#!/bin/sh\ntrap '' TERM\necho $$ > \(ready)\nwhile :; do sleep 1; done\n"
            case .crashing:
                return "#!/bin/sh\necho $$ > \(ready)\nexit 7\n"
            }
        }
    }

    let tmp: URL
    let ready: URL
    let xrayPath: String
    let socketPath: String
    private(set) var env: HelperEnv
    private(set) var supervisor: Supervisor

    private var serverFD: Int32 = -1
    private var clientFDs: [Int32] = []
    private var subprocesses: [Process] = []

    init(script: Script) throws {
        tmp = try makeTmp()
        ready = tmp.appendingPathComponent("ready")
        socketPath = tmp.appendingPathComponent("s.sock").path

        let exe = tmp.appendingPathComponent("bin/sing-box")
        try writeFile(exe, contents: script.source(ready: ready.path), mode: 0o755)

        let xray = tmp.appendingPathComponent("xray")
        try writeFile(xray, contents: "", mode: 0o755)
        xrayPath = xray.path

        var e = HelperEnv.testing(tmp: tmp)
        e.socketPath = socketPath
        env = e
        supervisor = Supervisor(env: e)
    }

    /// Дать проверке подправить окружение до того, как оно разъедется по
    /// Supervisor и accept-циклу.
    func withEnv(_ mutate: (inout HelperEnv) -> Void) -> Stand {
        mutate(&env)
        supervisor = Supervisor(env: env)
        return self
    }

    // -- запуск демона ---------------------------------------------------

    /// Поднять обслуживание в этом же процессе.
    @discardableResult
    func serveHere() throws -> Stand {
        serverFD = try listenOnSocket(env)
        let fd = serverFD
        let sup = supervisor
        let e = env
        let t = Thread {
            while true {
                let conn = accept(fd, nil, nil)
                if conn < 0 { return }
                let worker = Thread { serveClient(fd: conn, sup: sup, env: e) }
                worker.stackSize = 512 * 1024
                worker.start()
            }
        }
        t.stackSize = 512 * 1024
        t.start()
        return self
    }

    /// Поднять демона отдельным процессом — иначе не послать ему сигнал.
    @discardableResult
    func serveSubprocess(expectFailure: Bool = false) throws -> Process {
        let p = Process()
        p.executableURL = try helperBinary()
        p.environment = [
            "SCVPN_HELPER_BIN_DIR": env.binDir.path,
            "SCVPN_HELPER_RUN_DIR": env.runDir.path,
            "SCVPN_HELPER_SOCKET": socketPath,
            "SCVPN_HELPER_LOCK": env.lockPath,
            "SCVPN_HELPER_SKIP_BINARY_CHECK": "1",
            "SCVPN_HELPER_STOP_GRACE": "1",
            "SCVPN_HELPER_KILL_GRACE": "1",
            "SCVPN_HELPER_SWEEP_GRACE": "1",
        ]
        // Логи демона в отдельный файл: иначе они перемешиваются с выводом
        // XCTest и читать провал невозможно.
        let logPath = tmp.appendingPathComponent("daemon-\(subprocesses.count).log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logPath)
        p.standardError = handle
        p.standardOutput = handle
        try p.run()
        subprocesses.append(p)

        if expectFailure {
            p.waitUntilExit()
            return p
        }
        // Готовность — это принятое соединение, а не появившийся файл сокета:
        // между bind и listen окно, в котором connect отвергается.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let fd = try? rawConnect() {
                close(fd)
                return p
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        throw HelperError("демон не поднялся за 10 с. Его лог:\n\(log)")
    }

    private func helperBinary() throws -> URL {
        // Тестовый бандл лежит в той же папке сборки, что и SCVPNHelper.
        let dir = Bundle(for: Stand.self).bundleURL.deletingLastPathComponent()
        let exe = dir.appendingPathComponent("SCVPNHelper")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw HelperError("не нашёл собранный SCVPNHelper рядом с тестами: \(exe.path)")
        }
        return exe
    }

    // -- клиенты ----------------------------------------------------------

    private func rawConnect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError("socket() не удался") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard ok == 0 else {
            close(fd)
            throw HelperError("connect(\(socketPath)) не удался: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    func connect(timeout: TimeInterval = 15) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let fd = try? rawConnect() {
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                clientFDs.append(fd)
                return fd
            }
            if Date() >= deadline {
                throw HelperError("не смог подключиться к \(socketPath) за \(timeout) с")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    @discardableResult
    func ask(_ fd: Int32, _ req: [String: Any]) throws -> [String: Any] {
        try send(fd, req)
        return try reply(fd)
    }

    func send(_ fd: Int32, _ req: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(UInt8(ascii: "\n"))
        guard writeAll(fd, data) else { throw HelperError("не смог отправить запрос") }
    }

    /// Ближайший кадр с ответом; строки логов пропускаем.
    func reply(_ fd: Int32) throws -> [String: Any] {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw HelperError("демон закрыл соединение, не ответив") }
            buf.append(contentsOf: chunk[0..<n])
            while let idx = buf.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buf[0..<idx])
                buf.removeSubrange(0...idx)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   obj["ok"] != nil {
                    return obj
                }
            }
        }
    }

    /// Поднять «туннель» через сокет и убедиться, что демон ответил согласием.
    func startTunnel() throws {
        let fd = try connect()
        let reply = try ask(fd, ["cmd": "start", "socks_port": 10808, "xray_path": xrayPath])
        guard reply["ok"] as? Bool == true else {
            throw HelperError("демон отказался поднимать туннель: \(reply)")
        }
    }

    // -- наблюдение -------------------------------------------------------

    func singboxPIDs() -> [String] {
        let pattern = escapedForPgrep("\(tmp.path)/bin/sing-box run -c")
        guard let r = runProcTool(["/usr/bin/pgrep", "-f", pattern]) else { return [] }
        return r.stdout.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Поднялся И готов: метку с собственным PID пишет сам поддельный sing-box.
    ///
    /// Сверяем PID из метки с живыми процессами — иначе метка, оставшаяся от
    /// прошлого sing-box на этом же стенде, сойдёт за готовность нового.
    func waitUp(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pids = singboxPIDs()
            if !pids.isEmpty,
               let marked = try? String(contentsOf: ready, encoding: .utf8),
               pids.contains(marked.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func waitGone(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if singboxPIDs().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Поднять sing-box с той же командной строкой, но без надзора.
    func spawnOrphan() throws {
        try FileManager.default.createDirectory(at: env.runDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: env.configPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec \(tmp.path)/bin/sing-box run -c \(env.configPath.path)"]
        try p.run()
        subprocesses.append(p)
        guard waitUp() else { throw HelperError("подложный сирота не поднялся") }
    }

    // -- уборка -----------------------------------------------------------

    func tearDown() {
        for p in subprocesses where p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }
        for fd in clientFDs { close(fd) }
        if serverFD >= 0 { close(serverFD) }
        supervisor.stop()
        _ = runProcTool(["/usr/bin/pkill", "-9", "-f",
                         escapedForPgrep("\(tmp.path)/bin/sing-box run -c")])
        try? FileManager.default.removeItem(at: tmp)
    }
}
