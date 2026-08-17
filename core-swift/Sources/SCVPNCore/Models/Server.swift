import Foundation

/// Один VPN-сервер: уже разобранные поля ссылки (`vless://` и т.п.).
///
/// Имена ключей на диске заморожены — это содержимое `profiles.json` у
/// пользователя. Отсюда `CodingKeys` целиком, а не выборочно: правка любого
/// имени молча потеряла бы поле при следующем чтении.
public struct Server: Codable, Equatable, Sendable {
    // --- основное ---
    /// `protocol` — зарезервированное слово Swift, поэтому поле зовётся
    /// `proto`. На диске ключ остаётся `protocol`: смена ключа сломала бы
    /// чтение существующих `profiles.json`.
    public var proto: String = "vless"      // vless | vmess | trojan | shadowsocks | wireguard
    public var name: String = ""            // отображаемое имя (из #fragment)
    public var address: String = ""         // хост или IP (у wireguard — Endpoint пира)
    public var port: Int = 443

    // --- учётные данные ---
    public var uuid: String = ""            // id для vless/vmess
    public var password: String = ""        // пароль для trojan
    public var method: String = ""          // шифр для shadowsocks
    public var alterID: Int = 0             // vmess alterId (обычно 0)

    // --- транспорт (streamSettings) ---
    public var network: String = "tcp"      // tcp | ws | grpc | http | quic | kcp
    public var security: String = "none"    // none | tls | reality
    public var flow: String = ""            // xtls-rprx-vision и т.п. (vless)

    // TLS / Reality
    public var sni: String = ""             // serverName
    public var fingerprint: String = ""     // uTLS fingerprint (chrome/firefox/…)
    public var alpn: String = ""            // h2,http/1.1
    public var publicKey: String = ""       // Reality pbk
    public var shortID: String = ""         // Reality sid
    public var spiderX: String = "/"        // Reality spx
    public var allowInsecure: Bool = false  // пропускать ошибки сертификата (TLS)

    // параметры путей транспорта
    public var wsPath: String = "/"         // путь для ws / http
    public var wsHost: String = ""          // Host-заголовок для ws
    public var grpcService: String = ""     // serviceName для grpc

    // --- wireguard / AmneziaWG ---
    // Публичный ключ пира лежит в общем `publicKey`: у Reality то же значение
    // значит то же самое — «публичный ключ сервера», и отдельное поле только
    // размножило бы имена на диске.
    public var privateKey: String = ""      // приватный ключ клиента, base64
    public var presharedKey: String = ""    // PresharedKey, base64; пусто — нет
    public var localAddress: String = ""    // адреса интерфейса: "10.66.66.4/32,fd42::4/128"
    public var allowedIPs: String = ""      // "0.0.0.0/0,::/0"; пусто — полный
    public var wgDNS: String = ""           // DNS интерфейса через запятую
    public var mtu: Int = 0                 // 0 — взять 1420
    public var keepalive: Int = 0           // 0 — не слать
    /// Параметры обфускации AmneziaWG как `jc=10,jmin=47,…` в именах UAPI.
    ///
    /// Одной строкой намеренно: Amnezia добавляет параметры от версии к версии
    /// (jc…h4 были в 1.5, i1…i5 приехали во 2.0), и открытый список избавляет
    /// от правки четырёх платформ на каждый новый ключ. Пусто — это обычный
    /// WireGuard без обфускации, рабочий режим, а не ошибка.
    public var awg: String = ""

    /// Сырые параметры на всякий случай — и чтобы неизвестные ключи ссылки
    /// переживали круг чтение-запись.
    public var extra: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case proto = "protocol"
        case name, address, port, uuid, password, method
        case alterID = "alter_id"
        case network, security, flow, sni, fingerprint, alpn
        case publicKey = "public_key"
        case shortID = "short_id"
        case spiderX = "spider_x"
        case allowInsecure = "allow_insecure"
        case wsPath = "ws_path"
        case wsHost = "ws_host"
        case grpcService = "grpc_service"
        case privateKey = "private_key"
        case presharedKey = "preshared_key"
        case localAddress = "local_address"
        case allowedIPs = "allowed_ips"
        case wgDNS = "wg_dns"
        case mtu, keepalive, awg
        case extra
    }

    public init(proto: String = "vless", name: String = "", address: String = "",
                port: Int = 443, uuid: String = "", password: String = "",
                method: String = "", alterID: Int = 0, network: String = "tcp",
                security: String = "none", flow: String = "", sni: String = "",
                fingerprint: String = "", alpn: String = "", publicKey: String = "",
                shortID: String = "", spiderX: String = "/", allowInsecure: Bool = false,
                wsPath: String = "/", wsHost: String = "", grpcService: String = "",
                privateKey: String = "", presharedKey: String = "",
                localAddress: String = "", allowedIPs: String = "", wgDNS: String = "",
                mtu: Int = 0, keepalive: Int = 0, awg: String = "",
                extra: [String: JSONValue] = [:]) {
        self.proto = proto; self.name = name; self.address = address; self.port = port
        self.uuid = uuid; self.password = password; self.method = method
        self.alterID = alterID; self.network = network; self.security = security
        self.flow = flow; self.sni = sni; self.fingerprint = fingerprint; self.alpn = alpn
        self.publicKey = publicKey; self.shortID = shortID; self.spiderX = spiderX
        self.allowInsecure = allowInsecure; self.wsPath = wsPath; self.wsHost = wsHost
        self.grpcService = grpcService
        self.privateKey = privateKey; self.presharedKey = presharedKey
        self.localAddress = localAddress; self.allowedIPs = allowedIPs
        self.wgDNS = wgDNS; self.mtu = mtu; self.keepalive = keepalive; self.awg = awg
        self.extra = extra
    }

    /// Отсутствующие ключи берут значение по умолчанию, а не роняют разбор:
    /// `profiles.json` мог быть записан прежней версией, где поля ещё не было.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decode, а не decodeIfPresent: нужен один и тот же исход и когда
        // ключа нет, и когда под ним лежит не тот тип. Второе бывает — файл
        // правят руками.
        func str(_ k: CodingKeys, _ fallback: String) -> String {
            (try? c.decode(String.self, forKey: k)) ?? fallback
        }
        self.proto = str(.proto, "vless")
        self.name = str(.name, "")
        self.address = str(.address, "")
        self.port = (try? c.decode(Int.self, forKey: .port)) ?? 443
        self.uuid = str(.uuid, "")
        self.password = str(.password, "")
        self.method = str(.method, "")
        self.alterID = (try? c.decode(Int.self, forKey: .alterID)) ?? 0
        self.network = str(.network, "tcp")
        self.security = str(.security, "none")
        self.flow = str(.flow, "")
        self.sni = str(.sni, "")
        self.fingerprint = str(.fingerprint, "")
        self.alpn = str(.alpn, "")
        self.publicKey = str(.publicKey, "")
        self.shortID = str(.shortID, "")
        self.spiderX = str(.spiderX, "/")
        self.allowInsecure = (try? c.decode(Bool.self, forKey: .allowInsecure)) ?? false
        self.wsPath = str(.wsPath, "/")
        self.wsHost = str(.wsHost, "")
        self.grpcService = str(.grpcService, "")
        self.privateKey = str(.privateKey, "")
        self.presharedKey = str(.presharedKey, "")
        self.localAddress = str(.localAddress, "")
        self.allowedIPs = str(.allowedIPs, "")
        self.wgDNS = str(.wgDNS, "")
        self.mtu = (try? c.decode(Int.self, forKey: .mtu)) ?? 0
        self.keepalive = (try? c.decode(Int.self, forKey: .keepalive)) ?? 0
        self.awg = str(.awg, "")
        self.extra = (try? c.decode([String: JSONValue].self, forKey: .extra)) ?? [:]
    }

    /// Записываем поля wireguard только когда они заполнены.
    ///
    /// Синтезированный кодировщик писал бы восемь пустых ключей в каждую
    /// строчку каждого профиля — и, что важнее, менял бы уже лежащий на диске
    /// файл при первом же сохранении. Круг «прочитать-записать» обязан
    /// оставлять чужой файл байт в байт, иначе профиль, принесённый с другой
    /// платформы, тихо переписывается здешней версией формата.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(proto, forKey: .proto)
        try c.encode(name, forKey: .name)
        try c.encode(address, forKey: .address)
        try c.encode(port, forKey: .port)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(password, forKey: .password)
        try c.encode(method, forKey: .method)
        try c.encode(alterID, forKey: .alterID)
        try c.encode(network, forKey: .network)
        try c.encode(security, forKey: .security)
        try c.encode(flow, forKey: .flow)
        try c.encode(sni, forKey: .sni)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(alpn, forKey: .alpn)
        try c.encode(publicKey, forKey: .publicKey)
        try c.encode(shortID, forKey: .shortID)
        try c.encode(spiderX, forKey: .spiderX)
        try c.encode(allowInsecure, forKey: .allowInsecure)
        try c.encode(wsPath, forKey: .wsPath)
        try c.encode(wsHost, forKey: .wsHost)
        try c.encode(grpcService, forKey: .grpcService)
        try c.encode(extra, forKey: .extra)

        if !privateKey.isEmpty { try c.encode(privateKey, forKey: .privateKey) }
        if !presharedKey.isEmpty { try c.encode(presharedKey, forKey: .presharedKey) }
        if !localAddress.isEmpty { try c.encode(localAddress, forKey: .localAddress) }
        if !allowedIPs.isEmpty { try c.encode(allowedIPs, forKey: .allowedIPs) }
        if !wgDNS.isEmpty { try c.encode(wgDNS, forKey: .wgDNS) }
        if mtu != 0 { try c.encode(mtu, forKey: .mtu) }
        if keepalive != 0 { try c.encode(keepalive, forKey: .keepalive) }
        if !awg.isEmpty { try c.encode(awg, forKey: .awg) }
    }

    /// Сервер, который поднимает не Xray, а отдельный процесс `scvpn-awg`.
    public var isWireGuard: Bool { proto == "wireguard" }

    public var title: String {
        name.isEmpty ? "\(address):\(port)" : name
    }

    /// Грубый ключ для отсева дубликатов при обновлении подписки.
    ///
    /// Формат заморожен: он лежит в `settings.json` как `selected_key`, и
    /// смена формата потеряла бы выбранный сервер у каждого пользователя.
    public func key() -> String {
        // Третьим идёт публичный ключ: у wireguard нет ни uuid, ни пароля, и
        // без него два разных пира на одном host:port схлопнулись бы в один
        // ключ — то есть в одну строку списка и один `selected_key`. Формат
        // строки при этом не меняется, ключи vless и trojan прежние.
        var secret = uuid.isEmpty ? password : uuid
        if secret.isEmpty { secret = publicKey }
        return "\(proto)://\(secret)@\(address):\(port)/\(network)/\(security)"
    }

    // ------------------------------------------------------------------
    // Сборка outbound для Xray
    // ------------------------------------------------------------------
    public func toOutbound(tag: String = "proxy",
                           awgSocksPort: Int = defaultAWGPort) throws -> [String: Any] {
        // wireguard уходит первым и с ранним return: сам туннель держит
        // отдельный процесс `scvpn-awg`, а Xray только ходит в него как в
        // обычный SOCKS. Отсюда и отсутствие streamSettings — их добавляет
        // общий хвост метода, и для wireguard они не значат ничего.
        if isWireGuard {
            return [
                "tag": tag,
                "protocol": "socks",
                "settings": ["servers": [["address": "127.0.0.1",
                                          "port": awgSocksPort] as [String: Any]]],
            ]
        }

        var out: [String: Any] = ["tag": tag, "protocol": proto]

        switch proto {
        case "vless":
            var user: [String: Any] = ["id": uuid, "encryption": "none"]
            if !flow.isEmpty { user["flow"] = flow }
            out["settings"] = ["vnext": [["address": address, "port": port,
                                          "users": [user]] as [String: Any]]]
        case "vmess":
            let user: [String: Any] = ["id": uuid, "alterId": alterID, "security": "auto"]
            out["settings"] = ["vnext": [["address": address, "port": port,
                                          "users": [user]] as [String: Any]]]
        case "trojan":
            out["settings"] = ["servers": [["address": address, "port": port,
                                            "password": password] as [String: Any]]]
        case "shadowsocks":
            out["settings"] = ["servers": [["address": address, "port": port,
                                            "method": method,
                                            "password": password] as [String: Any]]]
        default:
            throw ValidationError("Неизвестный протокол: \(proto)")
        }

        out["streamSettings"] = streamSettings()
        return out
    }

    func streamSettings() -> [String: Any] {
        var ss: [String: Any] = ["network": network]

        // --- безопасность транспорта ---
        switch security {
        case "reality":
            ss["security"] = "reality"
            ss["realitySettings"] = [
                "serverName": sni,
                // Пустой отпечаток означает «панель его не прислала», а не
                // «отпечаток не нужен»: Reality без uTLS не работает.
                "fingerprint": fingerprint.isEmpty ? "chrome" : fingerprint,
                "publicKey": publicKey,
                "shortId": shortID,
                "spiderX": spiderX.isEmpty ? "/" : spiderX,
            ] as [String: Any]
        case "tls":
            ss["security"] = "tls"
            var tls: [String: Any] = [
                "serverName": sni.isEmpty ? address : sni,
                "allowInsecure": allowInsecure,
            ]
            if !fingerprint.isEmpty { tls["fingerprint"] = fingerprint }
            let alpns = alpn.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !alpns.isEmpty { tls["alpn"] = alpns }
            ss["tlsSettings"] = tls
        default:
            ss["security"] = "none"
        }

        // --- настройки конкретного транспорта ---
        switch network {
        case "ws":
            var ws: [String: Any] = ["path": wsPath.isEmpty ? "/" : wsPath]
            let host = wsHost.isEmpty ? sni : wsHost
            if !host.isEmpty { ws["headers"] = ["Host": host] }
            ss["wsSettings"] = ws
        case "grpc":
            ss["grpcSettings"] = ["serviceName": grpcService]
        case "http":   // h2
            var h: [String: Any] = ["path": wsPath.isEmpty ? "/" : wsPath]
            if !wsHost.isEmpty { h["host"] = [wsHost] }
            ss["httpSettings"] = h
        default:
            break   // tcp и прочее — без доп. настроек
        }

        return ss
    }
}
