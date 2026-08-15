import Foundation

/// Локальные порты по умолчанию. Слушают только `127.0.0.1`, наружу не торчат.
public let defaultSocksPort = 10808
public let defaultHTTPPort = 10809

/// Режимы маршрутизации.
public enum RouteMode: String, Sendable {
    /// Весь трафик через VPN, кроме локалки.
    case global
    /// Российские сайты и IP напрямую, остальное в VPN.
    case bypassRU = "bypass_ru"
}

/// Полный конфиг Xray из выбранного сервера.
///
/// Состоит из: `log` — куда писать логи ядра; `inbounds` — локальные входы
/// SOCKS и HTTP на `127.0.0.1`, в них ходит системный прокси или TUN-движок;
/// `outbounds` — наш сервер, прямой выход, чёрная дыра; `routing` — правила;
/// `dns`.
///
/// **Порядок правил маршрутизации значим** и повторён из Python дословно:
/// блокировка рекламы → приватные адреса и домены → обход РФ → всё остальное в
/// прокси. Xray берёт первое совпавшее правило, поэтому перестановка меняет
/// поведение, а не оформление.
public func buildXrayConfig(
    server: Server,
    socksPort: Int = defaultSocksPort,
    httpPort: Int = defaultHTTPPort,
    routeMode: RouteMode = .global,
    blockAds: Bool = false,
    logPath: String? = nil,
    logLevel: String = "warning",
    geoAssets: Bool = true
) throws -> [String: Any] {
    // Без гео-баз режимы, которые на них держатся, не «работают хуже», а не
    // работают вовсе. Отказ вместо тихой подмены поведения: иначе пользователь
    // включил бы «обход РФ» и получил глобальный режим, не узнав об этом.
    if !geoAssets {
        if routeMode == .bypassRU { throw XrayConfigError.geoRequired("обход РФ") }
        if blockAds { throw XrayConfigError.geoRequired("блокировка рекламы") }
    }
    var log: [String: Any] = ["loglevel": logLevel]
    if let logPath {
        log["access"] = logPath
        log["error"] = logPath
    }
    return [
        "log": log,
        "inbounds": inbounds(socksPort: socksPort, httpPort: httpPort),
        "outbounds": [
            try server.toOutbound(tag: "proxy"),
            ["tag": "direct", "protocol": "freedom", "settings": [:] as [String: Any]] as [String: Any],
            ["tag": "block", "protocol": "blackhole", "settings": [:] as [String: Any]] as [String: Any],
        ],
        "routing": routing(routeMode: routeMode, blockAds: blockAds, geoAssets: geoAssets),
        "dns": dns(routeMode: routeMode, geoAssets: geoAssets),
    ]
}

/// Конфиг просит того, чего в этой сборке нет.
public enum XrayConfigError: Error, Equatable, CustomStringConvertible {
    case geoRequired(String)
    public var description: String {
        switch self {
        case .geoRequired(let what):
            return "«\(what)» требует гео-баз, а в этой сборке их нет"
        }
    }
}

/// Приватные и служебные подсети — то же, что `geoip:private` в гео-базе Xray.
///
/// Нужны там, где баз нет: на iOS расширение туннеля живёт в лимите памяти
/// (50 МБ), и десятки мегабайт гео-данных туда не помещаются. Без этого списка
/// локальная сеть уехала бы в туннель.
public let privateCIDRs = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24",
    "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
    "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
    "::1/128", "fc00::/7", "fe80::/10",
]

/// Конфиг для замера задержки до сервера.
///
/// Инбаундов нет: ядро поднимается внутри вызова `measureOutboundDelay`, ходит
/// на `probeURL` и гаснет. Гео-ссылок нет тоже — замер не должен зависеть от
/// наличия баз.
public func buildProbeConfig(server: Server) throws -> String {
    let cfg: [String: Any] = [
        "log": ["loglevel": "none"],
        "outbounds": [try server.toOutbound(tag: "proxy")],
    ]
    let data = try JSONSerialization.data(withJSONObject: cfg)
    return String(decoding: data, as: UTF8.self)
}

func inbounds(socksPort: Int, httpPort: Int) -> [[String: Any]] {
    let sniffing: [String: Any] = ["enabled": true, "destOverride": ["http", "tls", "quic"]]
    return [
        [
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": socksPort,
            "protocol": "socks",
            "settings": ["udp": true, "auth": "noauth"] as [String: Any],
            "sniffing": sniffing,
        ],
        [
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": httpPort,
            "protocol": "http",
            "settings": [:] as [String: Any],
            "sniffing": sniffing,
        ],
    ]
}

func routing(routeMode: RouteMode, blockAds: Bool, geoAssets: Bool = true) -> [String: Any] {
    var rules: [[String: Any]] = []

    // 1) реклама в чёрную дыру (по желанию)
    if blockAds {
        rules.append(["type": "field", "outboundTag": "block",
                      "domain": ["geosite:category-ads-all"]])
    }

    // 2) локальная сеть и приватные адреса — всегда напрямую
    if geoAssets {
        rules.append(["type": "field", "outboundTag": "direct", "ip": ["geoip:private"]])
        rules.append(["type": "field", "outboundTag": "direct", "domain": ["geosite:private"]])
    } else {
        // Без гео-баз то же самое явным списком: правило обязано остаться, иначе
        // локальная сеть уедет в туннель.
        rules.append(["type": "field", "outboundTag": "direct", "ip": privateCIDRs])
    }

    // 3) режим «обход РФ»: российские сайты и IP — напрямую
    if routeMode == .bypassRU {
        rules.append(["type": "field", "outboundTag": "direct",
                      "domain": ["geosite:category-ru", "geosite:yandex",
                                 "geosite:vk", "geosite:mailru"]])
        rules.append(["type": "field", "outboundTag": "direct", "ip": ["geoip:ru"]])
    }

    // 4) всё остальное — в VPN. Явное правило не обязательно (умолчание — первый
    //    outbound, то есть proxy), но пусть будет видно.
    rules.append(["type": "field", "outboundTag": "proxy", "network": "tcp,udp"])

    return ["domainStrategy": "IPIfNonMatch", "rules": rules]
}

func dns(routeMode: RouteMode, geoAssets: Bool = true) -> [String: Any] {
    // DNS через прокси, чтобы провайдер не видел запросы и не было утечки.
    var servers: [Any] = ["https://1.1.1.1/dns-query", "8.8.8.8"]
    if routeMode == .bypassRU && geoAssets {
        // Российские домены резолвим через российский DNS напрямую — иначе
        // они уедут в туннель вместе с запросом и обход перестанет быть обходом.
        servers.insert(["address": "77.88.8.8",              // Yandex DNS
                        "domains": ["geosite:category-ru"]] as [String: Any], at: 0)
    }
    return ["servers": servers, "queryStrategy": "UseIP"]
}
