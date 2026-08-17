import Foundation

/// Разбор и сборка `.conf` формата wg-quick, включая расширения AmneziaWG.
///
/// Это тот же файл, что даёт панель и что зашит в QR-код: содержимое QR —
/// ровно этот текст, поэтому сканер и вставка в поле ведут в один разбор.
///
/// Эталон — `awg/conf.go` в этом же репозитории: там он проверен на живом
/// сервере, и расхождение между ними означало бы, что приложение показывает
/// одно, а туннель поднимается по другому.

/// Параметры обфускации AmneziaWG в именах UAPI ядра.
///
/// Порядок фиксирован: по нему собирается строка `awg`, и одинаковый конфиг
/// обязан давать одинаковую строку, иначе `key()` начнёт расходиться.
public let awgParamNames = [
    "jc", "jmin", "jmax",
    "s1", "s2", "s3", "s4",
    "h1", "h2", "h3", "h4",
    "i1", "i2", "i3", "i4", "i5",
]

/// Похож ли текст на `.conf`, а не на ссылку или подписку.
public func looksLikeWireGuardConf(_ text: String) -> Bool {
    text.range(of: "[Interface]", options: .caseInsensitive) != nil
}

/// Разобрать `.conf` в `Server`. `nil` — не разобрался.
///
/// Не бросает, как и `parseLink`: разбор кормят и вставленным из буфера
/// мусором, и содержимым случайного файла.
public func parseWireGuardConf(_ text: String, name: String = "") -> Server? {
    var s = Server(proto: "wireguard")
    s.name = name
    s.port = 0                  // чтобы отличить «Endpoint без порта» от 443

    var section = ""
    var awg: [String: String] = [:]
    var addresses: [String] = []
    var allowed: [String] = []
    var dns: [String] = []

    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
        if line.hasPrefix("["), line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces).lowercased()
            continue
        }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex..<eq])
            .trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        if value.isEmpty { continue }

        switch (section, key) {
        case ("interface", "privatekey"):  s.privateKey = value
        case ("interface", "address"):     addresses += splitCommaList(value)
        case ("interface", "dns"):         dns += splitCommaList(value)
        case ("interface", "mtu"):         s.mtu = Int(value) ?? 0
        case ("peer", "publickey"):        s.publicKey = value
        case ("peer", "presharedkey"):     s.presharedKey = value
        case ("peer", "allowedips"):       allowed += splitCommaList(value)
        case ("peer", "persistentkeepalive"): s.keepalive = Int(value) ?? 0
        case ("peer", "endpoint"):
            let (host, port) = splitEndpoint(value)
            s.address = host
            s.port = port
        default:
            // Незнакомые ключи [Interface] — либо обфускация, либо то, что к
            // юзерспейс-стеку отношения не имеет (Table, PostUp и прочее).
            if section == "interface", awgParamNames.contains(key) {
                awg[key] = value
            }
        }
    }

    s.localAddress = addresses.joined(separator: ",")
    s.allowedIPs = allowed.joined(separator: ",")
    s.wgDNS = dns.joined(separator: ",")
    s.awg = joinAWG(awg)

    return validWireGuard(s)
}

/// Проверка того, без чего туннель не поднимется.
///
/// Общая для `.conf` и для ссылки: разойдись они — одна форма принимала бы то,
/// что другая отвергает, и сервер молча не работал бы.
func validWireGuard(_ s: Server) -> Server? {
    var s = s
    guard !s.privateKey.isEmpty, !s.publicKey.isEmpty,
          !s.address.isEmpty, s.port > 0, !s.localAddress.isEmpty
    else { return nil }
    // Ключи обязаны быть 32 байтами base64. Обрезанный ключ ядро приняло бы
    // молча, и туннель не поднялся бы без внятной причины.
    guard isWireGuardKey(s.privateKey), isWireGuardKey(s.publicKey),
          s.presharedKey.isEmpty || isWireGuardKey(s.presharedKey)
    else { return nil }
    // Пустой AllowedIPs у wg-quick значит «ничего не маршрутизировать», но в
    // клиентском конфиге это всегда опечатка: туннель поднимется и не
    // пропустит ни байта.
    if s.allowedIPs.isEmpty { s.allowedIPs = "0.0.0.0/0,::/0" }
    return s
}

func isWireGuardKey(_ value: String) -> Bool {
    Data(base64Encoded: value)?.count == 32
}

/// Собрать `.conf` обратно — его читает процесс `scvpn-awg`.
public func wireGuardConfText(_ s: Server) -> String {
    var lines = ["[Interface]", "PrivateKey = \(s.privateKey)"]
    if !s.localAddress.isEmpty { lines.append("Address = \(s.localAddress)") }
    if !s.wgDNS.isEmpty { lines.append("DNS = \(s.wgDNS)") }
    if s.mtu != 0 { lines.append("MTU = \(s.mtu)") }
    for (key, value) in splitAWG(s.awg) where !value.isEmpty {
        // Регистр имени неважен — разбор в ядре идёт по нижнему.
        lines.append("\(key) = \(value)")
    }

    lines += ["", "[Peer]", "PublicKey = \(s.publicKey)"]
    if !s.presharedKey.isEmpty { lines.append("PresharedKey = \(s.presharedKey)") }
    lines.append("Endpoint = \(joinEndpoint(host: s.address, port: s.port))")
    lines.append("AllowedIPs = \(s.allowedIPs.isEmpty ? "0.0.0.0/0,::/0" : s.allowedIPs)")
    if s.keepalive != 0 { lines.append("PersistentKeepalive = \(s.keepalive)") }

    return lines.joined(separator: "\n") + "\n"
}

// --- мелочи, общие для разбора ссылки и файла ---

func splitCommaList(_ value: String) -> [String] {
    value.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// `host:port`, где host бывает IPv6-литералом в квадратных скобках.
func splitEndpoint(_ value: String) -> (String, Int) {
    if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
        let host = String(value[value.index(after: value.startIndex)..<close])
        let after = value[value.index(after: close)...]
        return (host, after.hasPrefix(":") ? (Int(after.dropFirst()) ?? 0) : 0)
    }
    guard let colon = value.lastIndex(of: ":") else { return (value, 0) }
    return (String(value[value.startIndex..<colon]),
            Int(value[value.index(after: colon)...]) ?? 0)
}

func joinEndpoint(host: String, port: Int) -> String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
}

/// `jc=10,jmin=47,…` — в порядке `awgParamNames`, пропуская незаданные.
func joinAWG(_ params: [String: String]) -> String {
    awgParamNames.compactMap { name in
        params[name].map { "\(name)=\($0)" }
    }.joined(separator: ",")
}

func splitAWG(_ value: String) -> [(String, String)] {
    value.split(separator: ",").compactMap { pair in
        guard let eq = pair.firstIndex(of: "=") else { return nil }
        let key = String(pair[pair.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let v = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return awgParamNames.contains(key.lowercased()) ? (key.lowercased(), v) : nil
    }
}
