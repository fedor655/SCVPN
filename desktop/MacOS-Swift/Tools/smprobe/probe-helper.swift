// Демон-зонд. Делает ровно две вещи: отмечается в журнале при каждом запуске и
// продолжает жить, чтобы launchd было что перезапускать.
//
// Версия зашита при сборке (probe-version.swift), потому что Задача 0.2
// спрашивает именно «чей код поднялся после подмены .app», а по PID этого не
// видно.
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

note("helper alive, version=\(probeVersion) pid=\(getpid()) euid=\(geteuid()) "
     + "exe=\(CommandLine.arguments.first ?? "?")")

// Живём вечно: без этого launchd с KeepAlive крутил бы перезапуски по кругу, и
// Задача 0.4 («сменился ли PID после kill -9») не отличила бы одно от другого.
dispatchMain()
