// Только macOS: демон, sing-box, системный прокси и дочерние процессы.
// На iOS ничего этого нет — там туннель поднимает NEPacketTunnelProvider.
#if os(macOS)
import Foundation

/// Управление системным прокси macOS.
///
/// macOS хранит прокси не глобально, а на каждом сетевом сервисе, и правятся
/// они утилитой `networksetup`. Администратору она доступна без пароля, поэтому
/// режим прокси, в отличие от TUN, никаких повышений прав не требует.
///
/// Настраиваем только сервисы за реальным устройством (Wi-Fi, Ethernet):
/// записей VPN-конфигов в системе бывают десятки, прокси им ни к чему, а обход
/// их всех занимал бы секунды.
///
/// **Снимок — единственное разрешение что-либо откатывать.** Нет снимка —
/// значит этот прокси ставили не мы, и трогать его нельзя: на машине
/// пользователя обычно живёт ещё один-два клиента (Happ, Tailscale и подобные),
/// и все они прописывают себе ровно тот же `127.0.0.1`, только на своём порту.
/// Без такой проверки один запуск SCVPN вхолостую — открыл и закрыл, ни разу не
/// подключившись — стирал бы чужую настройку на всех сетевых сервисах разом.
public enum SystemProxy {

    /// Обход прокси для локальных адресов.
    static let bypassList = [
        "localhost", "127.0.0.1", "10.0.0.0/8", "172.16.0.0/12",
        "192.168.0.0/16", "*.local",
    ]

    /// Два вида прокси и команды к каждому: чтение, установка, состояние.
    ///
    /// SOCKS сюда намеренно не входит: наружу мы отдаём только HTTP-порт Xray,
    /// а записать его в `-setsocksfirewallproxy` значило бы отправить
    /// SOCKS-клиентов на HTTP-инбаунд. Кому нужен весь трафик — тому TUN.
    static let kinds: [(kind: String, get: String, set: String, setState: String)] = [
        ("web", "-getwebproxy", "-setwebproxy", "-setwebproxystate"),
        ("secure", "-getsecurewebproxy", "-setsecurewebproxy", "-setsecurewebproxystate"),
    ]

    /// Как звать `networksetup`. Поле, а не прямой вызов: проверки подменяют
    /// его поддельной сетью, иначе каждая из них правила бы настройки машины,
    /// на которой запущена.
    public static var runNetworksetup: ([String]) -> String = { args in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Файл со снимком: что стояло у каждого сервиса до нашего вмешательства.
    static var snapshotFile: URL { Paths.dataDir.appendingPathComponent("sysproxy_backup.json") }

    // ------------------------------------------------------------------
    // Чтение состояния
    // ------------------------------------------------------------------

    /// Включённые сетевые сервисы, за которыми стоит реальное устройство.
    ///
    /// Строки `-listnetworkserviceorder` идут парами:
    /// ```
    /// (4) Wi-Fi
    /// (Hardware Port: Wi-Fi, Device: en0)
    /// ```
    /// У выключенных сервисов вместо номера стоит звёздочка, у VPN-конфигов
    /// второй строки нет вовсе.
    public static func hardwareServices() -> [String] {
        var services: [String] = []
        var pending: String?
        for raw in runNetworksetup(["-listnetworkserviceorder"]).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = matchOrder(line) {
                pending = m.index == "*" ? nil : m.name
                continue
            }
            if let device = matchHardwarePort(line) {
                if let name = pending, !device.isEmpty { services.append(name) }
                pending = nil
            }
        }
        return services
    }

    /// `(4) Wi-Fi` -> `("4", "Wi-Fi")`.
    static func matchOrder(_ line: String) -> (index: String, name: String)? {
        guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
        let index = String(line[line.index(after: line.startIndex)..<close])
        guard !index.isEmpty, index == "*" || index.allSatisfy(\.isNumber) else { return nil }
        let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (index, name)
    }

    /// `(Hardware Port: Wi-Fi, Device: en0)` -> `"en0"`.
    static func matchHardwarePort(_ line: String) -> String? {
        guard line.hasPrefix("(Hardware Port:"), line.hasSuffix(")"),
              let r = line.range(of: "Device:") else { return nil }
        return String(line[r.upperBound...].dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// Список обхода прокси сервиса — по домену на строку.
    static func readBypass(_ service: String) -> [String] {
        let lines = runNetworksetup(["-getproxybypassdomains", service])
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Пустой список networksetup описывает не пустым выводом, а
        // человеческой фразой вида «There aren't any bypass domains set on
        // Wi-Fi.» — сравнивать с ней целиком нельзя, она содержит имя сервиса и
        // меняется между версиями macOS. Домены пробелов не содержат, а фраза
        // это предложение с пробелами, этим и отличаем.
        return lines.filter { !$0.contains(" ") }
    }

    /// Текущие настройки прокси одного сервиса.
    static func readState(_ service: String) -> ServiceState {
        var state = ServiceState()
        for k in kinds {
            var fields: [String: String] = [:]
            for raw in runNetworksetup([k.get, service]).split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[line.startIndex..<colon])
                guard ["Enabled", "Server", "Port"].contains(key) else { continue }
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            state.kinds[k.kind] = fields
        }
        state.bypass = readBypass(service)
        return state
    }

    // ------------------------------------------------------------------
    // Снимок
    // ------------------------------------------------------------------

    struct ServiceState: Codable, Equatable {
        var kinds: [String: [String: String]] = [:]
        var bypass: [String] = []
    }

    struct Snapshot: Equatable {
        var services: [String: ServiceState] = [:]
        var proxy: (host: String, port: Int)?

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.services == b.services && a.proxy?.host == b.proxy?.host
                && a.proxy?.port == b.proxy?.port
        }
    }

    /// Снимок с диска, или `nil`, если его нет либо он нечитаем.
    ///
    /// Понимает и прежний формат — тот, где сервисы лежали прямо в корне, а
    /// свой адрес мы никуда не писали. Понять его надо: он хранит **настоящее**
    /// прежнее состояние сети, и потерять эту запись значит потерять настройки,
    /// ради сохранности которых снимок и заводился.
    static func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var snapshot = Snapshot()
        let rawServices: [String: Any]
        if let nested = root["services"] as? [String: Any] {
            rawServices = nested
            if let proxy = root["proxy"] as? [String: Any] {
                let host = proxy["host"] as? String ?? ""
                let port = (proxy["port"] as? NSNumber)?.intValue
                    ?? Int(proxy["port"] as? String ?? "") ?? 0
                snapshot.proxy = (host, port)
            }
        } else {
            rawServices = root      // прежний формат, без блока proxy
        }

        for (name, value) in rawServices {
            guard let fields = value as? [String: Any] else { continue }
            var state = ServiceState()
            for k in kinds {
                if let kv = fields[k.kind] as? [String: String] { state.kinds[k.kind] = kv }
            }
            state.bypass = fields["bypass"] as? [String] ?? []
            snapshot.services[name] = state
        }
        return snapshot
    }

    static func writeSnapshot(_ snapshot: Snapshot) {
        var services: [String: Any] = [:]
        for (name, state) in snapshot.services {
            var fields: [String: Any] = ["bypass": state.bypass]
            for (kind, kv) in state.kinds { fields[kind] = kv }
            services[name] = fields
        }
        var root: [String: Any] = ["services": services]
        if let proxy = snapshot.proxy {
            root["proxy"] = ["host": proxy.host, "port": proxy.port] as [String: Any]
        }
        Paths.ensureDirs()
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        else { return }
        try? data.write(to: snapshotFile, options: .atomic)
    }

    // ------------------------------------------------------------------
    // Включение и выключение
    // ------------------------------------------------------------------

    /// Включить системный HTTP/HTTPS-прокси на `host:port`.
    public static func enable(host: String = "127.0.0.1", port: Int = defaultHTTPPort) throws {
        let services = hardwareServices()
        guard !services.isEmpty else {
            throw ValidationError("Не нашлось активных сетевых сервисов для настройки прокси")
        }

        // Состояние сервисов запоминаем до первого изменения и только если
        // снимка ещё нет: повторный enable поверх включённого не должен
        // запомнить наши же настройки как «было». А вот адрес пишем всегда
        // свежий — порт выбирается при каждом подключении заново
        // (findFreePort), и по устаревшему потом не опознать свой прокси.
        var snapshot = loadSnapshot() ?? Snapshot()
        if snapshot.services.isEmpty {
            for s in services { snapshot.services[s] = readState(s) }
        }
        snapshot.proxy = (host, port)
        writeSnapshot(snapshot)

        for service in services {
            for k in kinds {
                // Последний аргумент off — прокси без авторизации.
                _ = runNetworksetup([k.set, service, host, String(port), "off"])
            }
            _ = runNetworksetup(["-setproxybypassdomains", service] + bypassList)
        }
    }

    /// Выключить системный прокси и вернуть то, что стояло до нас.
    ///
    /// **Без снимка не делаем ничего.** Снимок — это и есть запись «прокси
    /// ставили мы», и одновременно единственный источник знания, к чему
    /// возвращать. Без него прежняя версия выставляла всем сервисам пустой
    /// `Server`, `off` и bypass `Empty` — то есть стирала настройку чужого
    /// клиента, даже если SCVPN сам в этот запуск ничего не включал.
    public static func disable() {
        guard let snapshot = loadSnapshot() else { return }

        for service in hardwareServices() {
            // Сервиса не было в снимке — значит его прокси мы не трогали
            // (например, кабель воткнули уже после включения). Возвращать его
            // «как было» нам не к чему и не по праву.
            guard let was = snapshot.services[service] else { continue }
            for k in kinds {
                let fields = was.kinds[k.kind] ?? [:]
                // -set*proxy сам взводит Enabled даже при пустом Server,
                // поэтому нужное состояние выставляем отдельной командой
                // следом. Без этого шага, если «было» пусто и выключено,
                // Server и Port от нашего enable() тихо остаются висеть.
                _ = runNetworksetup([k.set, service, fields["Server"] ?? "",
                                     fields["Port"] ?? "0", "off"])
                _ = runNetworksetup([k.setState, service,
                                     fields["Enabled"] == "Yes" ? "on" : "off"])
            }
            // Список обхода возвращаем к тому, что было. Пустой список
            // networksetup описывает словом Empty.
            let bypass = was.bypass.isEmpty ? ["Empty"] : was.bypass
            _ = runNetworksetup(["-setproxybypassdomains", service] + bypass)
        }

        try? FileManager.default.removeItem(at: snapshotFile)
    }

    /// Стоит ли сейчас **наш** прокси хотя бы на одном сервисе.
    ///
    /// Два условия, и оба нужны.
    ///
    /// Снимок: он есть, только если включали мы. Переживает и падение
    /// приложения — следующий запуск по нему и опознает свою работу, и откатит.
    ///
    /// Адрес: на `127.0.0.1` сидят и другие VPN-клиенты, поэтому по одному лишь
    /// хосту чужой прокси от своего не отличить. Новый снимок содержит и порт —
    /// сверяем оба. Снимок прежнего формата портом не располагал: в нём
    /// сверяемся только по хосту, и это безопасно, потому что чужой клиент
    /// своего снимка у нас не оставляет.
    public static func systemProxyIsOurs() -> Bool {
        guard let snapshot = loadSnapshot() else { return false }

        let hasNewFormat = snapshot.proxy != nil
        let host: String
        let port: String
        if let proxy = snapshot.proxy {
            guard !proxy.host.isEmpty, proxy.port != 0 else { return false }
            host = proxy.host
            port = String(proxy.port)
        } else {
            host = "127.0.0.1"   // умолчание прежнего формата
            port = ""
        }

        for service in hardwareServices() {
            let web = readState(service).kinds["web"] ?? [:]
            guard web["Enabled"] == "Yes", web["Server"] == host else { continue }
            if !hasNewFormat { return true }
            if web["Port"] == port { return true }
        }
        return false
    }
}
#endif
