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
    public var proto: String = "vless"      // vless | vmess | trojan | shadowsocks
    public var name: String = ""            // отображаемое имя (из #fragment)
    public var address: String = ""         // хост или IP
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
        case extra
    }

    public init(proto: String = "vless", name: String = "", address: String = "",
                port: Int = 443, uuid: String = "", password: String = "",
                method: String = "", alterID: Int = 0, network: String = "tcp",
                security: String = "none", flow: String = "", sni: String = "",
                fingerprint: String = "", alpn: String = "", publicKey: String = "",
                shortID: String = "", spiderX: String = "/", allowInsecure: Bool = false,
                wsPath: String = "/", wsHost: String = "", grpcService: String = "",
                extra: [String: JSONValue] = [:]) {
        self.proto = proto; self.name = name; self.address = address; self.port = port
        self.uuid = uuid; self.password = password; self.method = method
        self.alterID = alterID; self.network = network; self.security = security
        self.flow = flow; self.sni = sni; self.fingerprint = fingerprint; self.alpn = alpn
        self.publicKey = publicKey; self.shortID = shortID; self.spiderX = spiderX
        self.allowInsecure = allowInsecure; self.wsPath = wsPath; self.wsHost = wsHost
        self.grpcService = grpcService; self.extra = extra
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
        self.extra = (try? c.decode([String: JSONValue].self, forKey: .extra)) ?? [:]
    }

    public var title: String {
        name.isEmpty ? "\(address):\(port)" : name
    }

    /// Грубый ключ для отсева дубликатов при обновлении подписки.
    ///
    /// Формат заморожен: он лежит в `settings.json` как `selected_key`, и
    /// смена формата потеряла бы выбранный сервер у каждого пользователя.
    public func key() -> String {
        let secret = uuid.isEmpty ? password : uuid
        return "\(proto)://\(secret)@\(address):\(port)/\(network)/\(security)"
    }

    // ------------------------------------------------------------------
    // Сборка outbound для Xray
    // ------------------------------------------------------------------
    public func toOutbound(tag: String = "proxy") throws -> [String: Any] {
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
