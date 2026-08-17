import Foundation

public let probeURL = "https://api.ipify.org"

/// Куда ходит замер пинга.
///
/// Не `probeURL`: 204-й ответ пустой, и в измеренное время не попадает ни
/// тело, ни его разбор — остаётся то, ради чего замер и делается. Тот же
/// адрес использует Android (`XrayCore.measureDelay`), поэтому числа на двух
/// платформах сравнимы между собой.
public let pingURL = "https://www.gstatic.com/generate_204"

/// Сколько отпечатков перебирать при замере.
///
/// Меньше, чем при подключении: там перебор идёт один раз и ради того, чтобы
/// соединение вообще состоялось, а здесь — по каждому серверу списка, и цена
/// умножается на их число.
public let pingFingerprintTries = 3

/// Порядок проверки: сперва те, что не шлют пост-квантовых кривых.
///
/// **Порядок не менять.** В свежих сборках Xray отпечаток `chrome` шлёт
/// X25519MLKEM768, которую часть серверов не понимает — соединение виснет.
/// `randomized` выбирает отпечаток случайно, отчего коннект нестабилен, и
/// поэтому стоит последним.
public let fallbackFingerprints = ["firefox", "chrome", "safari", "edge", "ios", "randomized"]

/// Отпечатки для проверки в порядке предпочтения.
public func candidateFingerprints(_ s: Server, override: String) -> [String] {
    if !override.isEmpty && override != "auto" {
        return [override]   // пользователь выбрал конкретный — без подбора
    }
    var candidates: [String] = []
    let fp = s.fingerprint.lowercased()
    // Отпечаток из подписки идёт первым, но только если он конкретный:
    // randomized означает «панель не знает», а не «панель просит случайный».
    if !fp.isEmpty && fp != "randomized" && fp != "random" {
        candidates.append(fp)
    }
    for f in fallbackFingerprints where !candidates.contains(f) {
        candidates.append(f)
    }
    return candidates
}

/// Замерщик задержки: конфиг на вход, миллисекунды или -1 на выход.
///
/// Протокол, а не прямой вызов, потому что способ замера у платформ разный:
/// macOS поднимает `xray` дочерним процессом и ходит через `curl`, iOS зовёт
/// libXray внутри процесса. Проверкам подсовывается подделка — иначе порядок
/// кандидатов проверялся бы только руками.
public protocol DelayMeasuring {
    func measure(configJSON: String, url: String) -> Int
}

/// Первый отпечаток, с которым сервер ответил.
///
/// Ни один не ответил — первый кандидат, как в `connect.py`: лучше попробовать
/// подключиться заведомым кандидатом, чем не пробовать вовсе.
public func findWorkingFingerprint(
    _ server: Server,
    override: String = "auto",
    using measurer: DelayMeasuring,
    log: @escaping (String) -> Void = { _ in }
) -> String {
    let candidates = candidateFingerprints(server, override: override)
    // Конкретный выбор пользователя не проверяем: он его и просил.
    if candidates.count == 1 { return candidates[0] }

    log("[*] Подбираю рабочий TLS-отпечаток…")
    for fp in candidates {
        var probe = server
        probe.fingerprint = fp
        guard let json = try? buildProbeConfig(server: probe) else { continue }
        if measurer.measure(configJSON: json, url: probeURL) > 0 {
            log("[+] Рабочий отпечаток: \(fp)")
            return fp
        }
        log("    \(fp) — не подошёл")
    }
    log("[!] Ни один отпечаток не прошёл проверку, пробую первый.")
    return candidates[0]
}

#if os(macOS)
/// Проверить один отпечаток на живом сервере.
///
/// Запрос идёт через `/usr/bin/curl -x`, а не через
/// `URLSessionConfiguration.connectionProxyDictionary`. Причина в риске,
/// записанном в плане (Задача 4.7): у связки HTTPS-через-CFNetwork-прокси
/// известны странности, а curl есть в macOS всегда и делает ровно то, что
/// написано. Проба ходит только на `api.ipify.org` и живёт секунды.
func probeFingerprint(_ server: Server, fp: String, routeMode: RouteMode,
                      blockAds: Bool, timeout: TimeInterval) -> Bool {
    var s = server
    s.fingerprint = fp
    return xrayDelay(s, routeMode: routeMode, blockAds: blockAds, timeout: timeout) != nil
}

/// Задержка запроса **через сам сервер**, в миллисекундах, или `nil`.
///
/// Отличие от `tcpPing` принципиальное. Тот меряет время установки TCP-
/// соединения, то есть отвечает на вопрос «порт открыт», а не «сервер
/// работает»: мёртвый VLESS на живом 443 показывался как честные 42 мс.
/// Здесь поднимается временное ядро с конфигом этого сервера, и через него
/// делается настоящий запрос — с рукопожатием протокола, TLS и всем, из-за
/// чего сервер и может не работать.
///
/// Плата известна: на каждый сервер уходит запуск `xray` и примерно полторы
/// секунды на подъём портов. Поэтому замер списка идёт с ограничением по
/// числу одновременных проб, а не веером.
///
/// Запрос идёт через `/usr/bin/curl -x`, а не через
/// `URLSessionConfiguration.connectionProxyDictionary`. Причина в риске,
/// записанном в плане (Задача 4.7): у связки HTTPS-через-CFNetwork-прокси
/// известны странности, а curl есть в macOS всегда и делает ровно то, что
/// написано.
/// `portBase` разводит одновременные пробы по разным диапазонам портов.
/// Без него две пробы, запущенные разом, выбирают один и тот же свободный
/// порт: `findFreePort` закрывает сокет сразу после проверки, и вторая проба
/// видит его свободным. Ядро второй пробы не поднимается, а сервер получает
/// «нет ответа» — проверено живьём на списке из двенадцати серверов.
/// Задержка до wireguard-сервера — замером внутри самого туннеля.
///
/// Работу делает сам `scvpn-awg` в режиме `-probe`: он поднимает туннель,
/// делает через него запрос и печатает миллисекунды. Так замер один на все
/// платформы, и здесь остаётся только запустить процесс и прочитать число.
///
/// Конфиг пишется во временный файл, а не в рабочий: замер идёт по всему
/// списку серверов сразу, и общий путь означал бы, что пробы затирают конфиг
/// друг другу — и заодно тот, по которому прямо сейчас поднят туннель.
public func awgDelay(_ server: Server, timeout: TimeInterval = 20.0) -> Int? {
    let exe = Paths.awgExe
    guard FileManager.default.fileExists(atPath: exe.path) else { return nil }

    let confPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("scvpn-probe-\(UUID().uuidString).conf")
    FileManager.default.createFile(atPath: confPath.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
    guard (try? Data(wireGuardConfText(server).utf8).write(to: confPath)) != nil else { return nil }
    defer { try? FileManager.default.removeItem(at: confPath) }

    let proc = Process()
    proc.executableURL = exe
    proc.arguments = ["-config", confPath.path, "-probe", pingURL]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return nil }

    // Сторож: рукопожатие к мёртвому серверу не завершается само — процесс
    // будет ждать своего таймаута, а список серверов встанет на нём.
    let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    watchdog.cancel()

    guard proc.terminationStatus == 0 else { return nil }
    return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

public func xrayDelay(_ server: Server, routeMode: RouteMode = .global,
                      blockAds: Bool = false, timeout: TimeInterval = 6.0,
                      portBase: Int = 20000, url: String = probeURL) -> Int? {
    let s = server
    let socksPort = findFreePort(preferred: portBase)
    let httpPort = findFreePort(preferred: max(portBase + 1, socksPort + 1))

    guard let cfg = try? buildXrayConfig(server: s, socksPort: socksPort, httpPort: httpPort,
                                         routeMode: routeMode, blockAds: blockAds,
                                         logLevel: "error") else { return nil }
    let runner = XrayRunner()
    guard (try? runner.start(cfg)) != nil else { return nil }
    defer {
        runner.stop()
        Thread.sleep(forTimeInterval: 0.3)
    }

    Thread.sleep(forTimeInterval: 1.3)   // дать ядру поднять порты

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    proc.arguments = ["-s", "-o", "/dev/null", "-m", "\(Int(timeout))",
                      "-x", "http://127.0.0.1:\(httpPort)", url]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    // Время считаем вокруг запроса, а не вокруг всей пробы: подъём ядра —
    // наша плата за честность, к задержке до сервера она отношения не имеет.
    let start = DispatchTime.now()
    guard (try? proc.run()) != nil else { return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return Int(ns / 1_000_000)
}

/// Задержка до сервера с перебором отпечатков — то, что показывает колонка
/// пинга.
///
/// Отдельно от `xrayDelay`, потому что у панелей сплошь и рядом стоит
/// `fingerprint: randomized`, а это значит «панель не знает», а не «сервер
/// просит случайный». Проба одним таким отпечатком проваливается, и живой
/// сервер получает «нет ответа» — ровно это и было видно на первом же
/// прогоне: двенадцать серверов, все «нет ответа».
public func pingDelay(_ server: Server, routeMode: RouteMode = .global,
                      blockAds: Bool = false, timeout: TimeInterval = 6.0,
                      portBase: Int = 20000) -> Int? {
    // У wireguard задержку меряет сам туннель: Xray подняться не сможет —
    // socks-выход смотрит в порт, которого без запущенного `scvpn-awg` нет.
    // TCP-пингом Endpoint тоже не измерить, WireGuard живёт на UDP.
    if server.isWireGuard {
        return awgDelay(server, timeout: timeout)
    }

    let candidates = Array(candidateFingerprints(server, override: "auto")
        .prefix(pingFingerprintTries))
    // Транспорт без TLS отпечатком не отличается — хватит одной пробы.
    let needsFingerprint = ["reality", "tls"].contains(server.security)
    guard needsFingerprint, candidates.count > 1 else {
        return xrayDelay(server, routeMode: routeMode, blockAds: blockAds,
                         timeout: timeout, portBase: portBase, url: pingURL)
    }
    for fp in candidates {
        var probe = server
        probe.fingerprint = fp
        if let ms = xrayDelay(probe, routeMode: routeMode, blockAds: blockAds,
                              timeout: timeout, portBase: portBase, url: pingURL) {
            return ms
        }
    }
    return nil
}

/// Первый рабочий отпечаток. Если ни один не прошёл — первый кандидат.
public func findWorkingFingerprint(
    _ server: Server,
    override: String = "auto",
    routeMode: RouteMode = .global,
    blockAds: Bool = false,
    log: @escaping (String) -> Void = { _ in },
    perProbeTimeout: TimeInterval = 6.0
) -> String {
    let candidates = candidateFingerprints(server, override: override)
    // Конкретный выбор пользователя не проверяем: он его и просил.
    if candidates.count == 1 { return candidates[0] }

    log("[*] Подбираю рабочий TLS-отпечаток…")
    for fp in candidates {
        if probeFingerprint(server, fp: fp, routeMode: routeMode,
                            blockAds: blockAds, timeout: perProbeTimeout) {
            log("[+] Рабочий отпечаток: \(fp)")
            return fp
        }
        log("    \(fp) — не подошёл")
    }
    log("[!] Ни один отпечаток не прошёл проверку, пробую первый.")
    return candidates[0]
}
#endif
