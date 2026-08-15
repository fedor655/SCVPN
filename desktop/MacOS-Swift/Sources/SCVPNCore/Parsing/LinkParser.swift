import Foundation

/// Разобрать одну ссылку в `Server`. `nil` — формат не распознан.
///
/// Не бросает намеренно: подписка — это сотня строк, и одна кривая среди них не
/// должна стоить пользователю всех остальных.
public func parseLink(_ link: String) -> Server? {
    let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
    if link.isEmpty { return nil }
    if link.hasPrefix("vless://")  { return parseVless(link) }
    if link.hasPrefix("vmess://")  { return parseVmess(link) }
    if link.hasPrefix("trojan://") { return parseTrojan(link) }
    if link.hasPrefix("ss://")     { return parseShadowsocks(link) }
    return nil
}

/// Параметры запроса, раскодированные **ровно один раз**.
///
/// Python здесь опирался на `parse_qs`, который декодирует сам, и поверх него
/// звал `unquote` ещё раз для `path`, `alpn` и `serviceName` — то есть
/// декодировал дважды. На живых ссылках это незаметно (после первого прохода
/// процентов не остаётся), но `path=%252F` приехал бы в конфиг как `/` вместо
/// `%2F`. Повторять этот баг незачем: декодируем один раз, все поля одинаково.
///
/// `+` в пробел не превращаем, в отличие от `parse_qs`: в значениях вроде
/// `pbk` лежит base64, и такая замена испортила бы ключ.
private func queryPairs(_ query: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in query.split(separator: "&") {
        guard let eq = pair.firstIndex(of: "=") else {
            let k = String(pair)
            if out[k] == nil { out[k] = "" }
            continue
        }
        let key = String(pair[pair.startIndex..<eq])
        let value = unescape(String(pair[pair.index(after: eq)...]))
        // Первое вхождение выигрывает — так же ведёт себя parse_qs + [0].
        if out[key] == nil { out[key] = value }
    }
    return out
}

private func unescape(_ s: String) -> String {
    s.removingPercentEncoding ?? s
}

/// Разбор `схема://userinfo@host:port?query#fragment` без URLComponents.
///
/// `URLComponents` спотыкается о то, что живьём встречается сплошь и рядом:
/// не-ASCII в `#fragment` (имя сервера по-русски), `:` и `/` внутри пароля
/// trojan. Своё разбиение по разделителям устойчивее и понятнее.
private struct LinkParts {
    var userInfo = ""
    var host = ""
    var port: Int?
    var query: [String: String] = [:]
    var fragment = ""
}

private func splitLink(_ link: String, scheme: String) -> LinkParts {
    var rest = String(link.dropFirst(scheme.count))
    var parts = LinkParts()

    if let hash = rest.firstIndex(of: "#") {
        parts.fragment = unescape(String(rest[rest.index(after: hash)...]))
        rest = String(rest[rest.startIndex..<hash])
    }
    if let q = rest.firstIndex(of: "?") {
        parts.query = queryPairs(String(rest[rest.index(after: q)...]))
        rest = String(rest[rest.startIndex..<q])
    }
    // rsplit по '@': пароль trojan вполне может содержать '@'.
    if let at = rest.lastIndex(of: "@") {
        parts.userInfo = unescape(String(rest[rest.startIndex..<at]))
        rest = String(rest[rest.index(after: at)...])
    }
    // Хост в квадратных скобках — IPv6-литерал.
    if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
        parts.host = String(rest[rest.index(after: rest.startIndex)..<close])
        let after = rest[rest.index(after: close)...]
        if after.hasPrefix(":") { parts.port = Int(after.dropFirst()) }
    } else if let colon = rest.lastIndex(of: ":") {
        parts.host = String(rest[rest.startIndex..<colon])
        parts.port = Int(rest[rest.index(after: colon)...])
    } else {
        parts.host = rest
    }
    return parts
}

private func extra(_ query: [String: String]) -> [String: JSONValue] {
    query.mapValues { JSONValue.string($0) }
}

private func parseVless(_ link: String) -> Server? {
    // vless://uuid@host:port?params#name
    let p = splitLink(link, scheme: "vless://")
    if p.host.isEmpty || p.userInfo.isEmpty { return nil }
    var s = Server(proto: "vless")
    s.uuid = p.userInfo
    s.address = p.host
    s.port = p.port ?? 443
    s.name = p.fragment
    s.network = p.query["type"] ?? "tcp"
    s.security = p.query["security"] ?? "none"
    s.flow = p.query["flow"] ?? ""
    s.sni = p.query["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? p.query["peer"] ?? ""
    s.fingerprint = p.query["fp"] ?? ""
    s.alpn = p.query["alpn"] ?? ""
    s.publicKey = p.query["pbk"] ?? ""
    s.shortID = p.query["sid"] ?? ""
    s.spiderX = p.query["spx"] ?? "/"
    s.wsPath = p.query["path"] ?? "/"
    s.wsHost = p.query["host"] ?? ""
    s.grpcService = p.query["serviceName"] ?? ""
    s.allowInsecure = ["1", "true"].contains(p.query["allowInsecure"] ?? "")
    s.extra = extra(p.query)
    return s
}

private func parseTrojan(_ link: String) -> Server? {
    // trojan://password@host:port?params#name
    let p = splitLink(link, scheme: "trojan://")
    if p.host.isEmpty || p.userInfo.isEmpty { return nil }
    var s = Server(proto: "trojan")
    s.password = p.userInfo
    s.address = p.host
    s.port = p.port ?? 443
    s.name = p.fragment
    s.network = p.query["type"] ?? "tcp"
    // У trojan умолчание security — tls, а не none: без TLS он не работает.
    s.security = p.query["security"] ?? "tls"
    s.sni = p.query["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? p.query["peer"] ?? ""
    s.fingerprint = p.query["fp"] ?? ""
    s.alpn = p.query["alpn"] ?? ""
    s.wsPath = p.query["path"] ?? "/"
    s.wsHost = p.query["host"] ?? ""
    s.grpcService = p.query["serviceName"] ?? ""
    s.allowInsecure = ["1", "true"].contains(p.query["allowInsecure"] ?? "")
    s.extra = extra(p.query)
    return s
}

private func parseVmess(_ link: String) -> Server? {
    // vmess://base64(json)
    let raw = String(link.dropFirst("vmess://".count))
    guard let text = try? b64decodeText(raw),
          let cfg = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return nil }

    func str(_ k: String) -> String {
        if let v = cfg[k] as? String { return v }
        if let v = cfg[k] as? NSNumber { return v.stringValue }
        return ""
    }
    func int(_ k: String, _ fallback: Int) -> Int {
        if let v = cfg[k] as? NSNumber { return v.intValue }
        if let v = cfg[k] as? String, let n = Int(v) { return n }
        return fallback
    }

    var s = Server(proto: "vmess")
    s.name = str("ps")
    s.address = str("add")
    s.port = int("port", 443)
    s.uuid = str("id")
    s.alterID = int("aid", 0)
    s.network = str("net").isEmpty ? "tcp" : str("net")
    s.security = str("tls").isEmpty ? "none" : str("tls")
    s.sni = str("sni").isEmpty ? str("host") : str("sni")
    s.fingerprint = str("fp")
    s.alpn = str("alpn")
    s.wsPath = str("path").isEmpty ? "/" : str("path")
    s.wsHost = str("host")
    // У grpc панели кладут имя сервиса в то же поле path.
    s.grpcService = s.network == "grpc" ? str("path") : ""
    s.extra = cfg.compactMapValues { value in
        if let v = value as? String { return .string(v) }
        if let v = value as? NSNumber { return .int(v.intValue) }
        return nil
    }
    if s.address.isEmpty { return nil }
    return s
}

private func parseShadowsocks(_ link: String) -> Server? {
    // Возможные формы:
    //   ss://base64(method:password)@host:port#name
    //   ss://base64(method:password@host:port)#name
    var s = Server(proto: "shadowsocks")
    var body = String(link.dropFirst("ss://".count))

    if let hash = body.firstIndex(of: "#") {
        s.name = unescape(String(body[body.index(after: hash)...]))
        body = String(body[body.startIndex..<hash])
    }
    // Параметры запроса у ss встречаются (plugin=…), но в модели им места нет —
    // отбрасываем, как это делал Python.
    if let q = body.firstIndex(of: "?") {
        body = String(body[body.startIndex..<q])
    }

    let methodPass: String
    let hostPart: String
    if let at = body.lastIndex(of: "@") {
        let userInfo = String(body[body.startIndex..<at])
        // userinfo бывает и base64, и открытым method:password.
        methodPass = (try? b64decodeText(userInfo)) ?? unescape(userInfo)
        hostPart = String(body[body.index(after: at)...])
    } else {
        guard let decoded = try? b64decodeText(body) else { return nil }
        guard let at = decoded.lastIndex(of: "@") else { return nil }
        methodPass = String(decoded[decoded.startIndex..<at])
        hostPart = String(decoded[decoded.index(after: at)...])
    }

    guard let colon = methodPass.firstIndex(of: ":") else { return nil }
    s.method = String(methodPass[methodPass.startIndex..<colon])
    s.password = String(methodPass[methodPass.index(after: colon)...])

    if let colon = hostPart.lastIndex(of: ":") {
        s.address = String(hostPart[hostPart.startIndex..<colon])
        s.port = Int(hostPart[hostPart.index(after: colon)...]) ?? 8388
    } else {
        s.address = hostPart
        s.port = 8388
    }
    if s.address.isEmpty || s.method.isEmpty { return nil }
    return s
}

/// Разобрать содержимое подписки в список серверов.
///
/// Подписка часто приходит как base64 от списка ссылок. Пробуем оба варианта и
/// берём тот, что дал больше серверов: угадывать по виду текста ненадёжно,
/// а лишний разбор стоит микросекунды.
public func parseSubscriptionText(_ text: String) -> [Server] {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidates = [text]
    if let decoded = try? b64decodeText(text) { candidates.append(decoded) }

    var best: [Server] = []
    for candidate in candidates {
        let servers = candidate.split(whereSeparator: \.isNewline).compactMap { parseLink(String($0)) }
        if servers.count > best.count { best = servers }
    }
    return best
}
