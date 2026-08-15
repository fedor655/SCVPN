// Демон-зонд. Делает ровно две вещи: отмечается в журнале при каждом запуске и
// продолжает жить, чтобы launchd было что перезапускать.
//
// Версия зашита при сборке (probe-version.swift), потому что Задача 0.2
// спрашивает именно «чей код поднялся после подмены .app», а по PID этого не
// видно.
import Darwin
import Foundation

let log = "/tmp/smprobe.log"

func note(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(text)\n"
    if let fh = FileHandle(forWritingAtPath: log) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        try? fh.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: log))
    }
    // Права на журнал даём всем: пишет его root, а читать будет пользователь.
    chmod(log, 0o666)
}

/// Абсолютный путь собственного бинарника.
///
/// `CommandLine.arguments[0]` под launchd — это `BundleProgram`, то есть путь
/// **относительно** бандла: `Contents/MacOS/smprobe-helper`. По нему нельзя
/// сказать, из какого бандла поднялся процесс, а Задачи 0.5 и 0.6 спрашивают
/// именно это. `proc_pidpath` отвечает без догадок.
func executablePath() -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(getpid(), &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : (CommandLine.arguments.first ?? "?")
}

note("helper alive, version=\(probeVersion) pid=\(getpid()) euid=\(geteuid()) "
     + "exe=\(executablePath())")

// Живём вечно: без этого launchd с KeepAlive крутил бы перезапуски по кругу, и
// Задача 0.4 («сменился ли PID после kill -9») не отличила бы одно от другого.
dispatchMain()
