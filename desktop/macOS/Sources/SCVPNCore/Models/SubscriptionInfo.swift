import Foundation

/// Служебные сведения о подписке, которые панель шлёт в заголовках ответа.
///
/// Стандарт де-факто у панелей (Marzban, Remnawave, 3x-ui): рядом со списком
/// серверов в HTTP-заголовках едут срок действия, потраченный трафик, интервал
/// автообновления, ссылка на поддержку. Приложение их просто показывает — сами
/// цифры считает панель, мы ничего не додумываем.
///
/// Чего в заголовках нет — того и не показываем. Даты активации подписки там не
/// бывает, поэтому в интерфейсе стоит дата, когда подписку добавили в
/// приложение, и подписана она именно так.
public struct SubscriptionInfo: Codable, Equatable, Sendable {
    public var title: String = ""           // profile-title
    public var account: String = ""         // имя файла из content-disposition, обычно логин
    public var upload: Int = 0              // байт
    public var download: Int = 0            // байт
    public var total: Int = 0               // байт, 0 = безлимит
    public var expire: Int = 0              // unix-время, 0 = бессрочно
    public var updateInterval: Int = 0      // часы
    public var supportURL: String = ""
    public var webPageURL: String = ""
    public var announce: String = ""
    public var hwid: [String: String] = [:]
    public var fetched: String = ""         // когда мы это прочитали

    enum CodingKeys: String, CodingKey {
        case title, account, upload, download, total, expire
        case updateInterval = "update_interval"
        case supportURL = "support_url"
        case webPageURL = "web_page_url"
        case announce, hwid, fetched
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        func int(_ k: CodingKeys) -> Int { (try? c.decode(Int.self, forKey: k)) ?? 0 }
        title = str(.title); account = str(.account)
        upload = int(.upload); download = int(.download)
        total = int(.total); expire = int(.expire)
        updateInterval = int(.updateInterval)
        supportURL = str(.supportURL); webPageURL = str(.webPageURL)
        announce = str(.announce); fetched = str(.fetched)
        hwid = (try? c.decode([String: String].self, forKey: .hwid)) ?? [:]
    }

    // ---------- производные величины, чтобы интерфейс не считал сам ----------

    public var used: Int { upload + download }

    public var unlimited: Bool { total <= 0 }

    /// Доля израсходованного лимита, 0…1. При безлимите — 0.
    public var usedRatio: Double {
        unlimited ? 0 : min(1, Double(used) / Double(total))
    }

    public var expiresAt: Date? {
        expire == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(expire))
    }

    public var daysLeft: Int? {
        guard let d = expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: d).day
    }

    public var deviceLimitReached: Bool {
        hwid["x-hwid-max-devices-reached"] == "true"
    }
}

/// Панели шлют название либо как есть, либо как `base64:…`.
func maybeBase64(_ value: String) -> String {
    guard value.hasPrefix("base64:") else { return value }
    let payload = String(value.dropFirst("base64:".count))
    guard let data = try? b64decode(payload) else { return value }
    return String(decoding: data, as: UTF8.self)
}

/// Собрать сведения из заголовков ответа панели.
public func subscriptionInfo(from headers: [AnyHashable: Any]) -> SubscriptionInfo {
    var h: [String: String] = [:]
    for (k, v) in headers { h["\(k)".lowercased()] = "\(v)" }

    var info = SubscriptionInfo()
    let f = DateFormatter()
    f.dateFormat = "dd.MM.yyyy HH:mm"
    info.fetched = f.string(from: Date())

    info.title = maybeBase64(h["profile-title"] ?? "")
    info.announce = maybeBase64(h["announce"] ?? "")
    info.supportURL = h["support-url"] ?? ""
    info.webPageURL = h["profile-web-page-url"] ?? ""

    // content-disposition: attachment; filename=F_Semin_key-1
    if let disp = h["content-disposition"], let r = disp.range(of: "filename=") {
        info.account = String(disp[r.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
    }

    // subscription-userinfo: upload=0; download=123; total=0; expire=1788405825
    for part in (h["subscription-userinfo"] ?? "").split(separator: ";") {
        let piece = part.trimmingCharacters(in: .whitespaces)
        guard let eq = piece.firstIndex(of: "=") else { continue }
        let key = String(piece[piece.startIndex..<eq])
        // Через Double: панели присылают и `0`, и `0.0`, и второе на строгом
        // разборе целого потеряло бы значение молча.
        guard let raw = Double(piece[piece.index(after: eq)...]) else { continue }
        let value = Int(raw)
        switch key {
        case "upload":   info.upload = value
        case "download": info.download = value
        case "total":    info.total = value
        case "expire":   info.expire = value
        default: break
        }
    }

    info.updateInterval = Int(h["profile-update-interval"] ?? "") ?? 0
    info.hwid = h.filter { $0.key.hasPrefix("x-hwid") }
    return info
}

// ----------------------------------------------------------------------
// Человеческие подписи — одни и те же во всех местах интерфейса
// ----------------------------------------------------------------------
public func humanBytes(_ n: Int) -> String {
    if n <= 0 { return "0 Б" }
    for (unit, size) in [("ТБ", 1 << 40), ("ГБ", 1 << 30), ("МБ", 1 << 20), ("КБ", 1 << 10)]
    where n >= size {
        return String(format: "%.2f %@", Double(n) / Double(size), unit)
    }
    return "\(n) Б"
}

/// Интервал автообновления. Панели шлют его в часах.
public func humanInterval(_ hours: Int) -> String {
    if hours <= 0 { return "не задано" }
    if hours % 24 == 0 {
        let days = hours / 24
        return days > 1 ? "раз в \(days) дн." : "раз в сутки"
    }
    return "раз в \(hours) ч."
}
