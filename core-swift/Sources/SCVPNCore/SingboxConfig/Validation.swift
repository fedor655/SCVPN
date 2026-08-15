import Foundation

/// Клиент прислал то, что демон не станет исполнять.
public struct ValidationError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

/// Потолок длины имени приложения. Заморожен вместе с протоколом.
public let maxAppNameBytes = 64

private let knownLogLevels: Set<String> = ["trace", "debug", "info", "warn", "error"]

/// Очищенный набор параметров sing-box. Собрать его можно только через
/// `validate`, поэтому дальше по коду проверок уже нет.
public struct SingboxParams: Sendable, Equatable {
    public let socksPort: Int
    public let splitMode: SplitMode
    public let splitApps: [String]
    public let stack: Stack
    public let excludeIPs: [String]
    public let logLevel: String
}

/// Число, но не булево.
///
/// `JSONSerialization` отдаёт и то, и другое как `NSNumber`, и `as? Int` на
/// булевом даёт 1 — ровно тот же подвох, что в Python, где `bool` подкласс
/// `int`. Отличить их можно только по типу CoreFoundation: `true` внутри
/// `NSNumber` — это `CFBoolean`, а не `CFNumber`.
private func isBoolean(_ value: Any) -> Bool {
    // И Swift-родной `true`, и булев NSNumber из JSONSerialization мостятся к
    // одному и тому же `kCFBooleanTrue`, поэтому одной проверки хватает на оба.
    CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
}

private func port(_ value: Any?) throws -> Int {
    guard let value else {
        throw ValidationError("порт должен быть целым числом, пришло nil")
    }
    guard !isBoolean(value), let number = value as? NSNumber,
          CFNumberIsFloatType(number) == false else {
        throw ValidationError("порт должен быть целым числом, пришло \(value)")
    }
    let intValue = number.intValue
    guard (1...65535).contains(intValue) else {
        throw ValidationError("порт вне диапазона: \(intValue)")
    }
    return intValue
}

/// Имя процесса для правила sing-box. Только имя — никаких путей.
private func appName(_ value: Any) throws -> String {
    guard let raw = value as? String else {
        throw ValidationError("имя приложения должно быть строкой, пришло \(value)")
    }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty {
        throw ValidationError("пустое имя приложения")
    }
    // Потолок в байтах, а не в символах: конфиг уезжает на диск в UTF-8, и
    // именно его длина имеет значение.
    if name.utf8.count > maxAppNameBytes {
        throw ValidationError("слишком длинное имя приложения: \(name.prefix(20))…")
    }
    if name.contains("/") || name.contains("\\") || name == "." || name == ".." {
        throw ValidationError("имя приложения не может быть путём: \(name)")
    }
    // Проверки на невалидный UTF-8 здесь нет, и это не упущение: Swift
    // `String` не умеет хранить одиночный суррогат — `JSONSerialization`
    // заменяет такое при разборе. В Python отбивать это приходилось руками,
    // иначе json.dumps().encode() падал уже внутри демона.
    return name
}

/// Проверить параметры от клиента и вернуть очищенный набор.
///
/// Принимает `Any`, а не `[String: Any]`, намеренно: кадр из сокета — это
/// разобранный JSON, который законно может оказаться списком, строкой или
/// числом. Со словарём в сигнатуре эта ветка отказа просто не существовала бы,
/// а вызывающему пришлось бы городить проверку у себя.
///
/// Невалидные IP молча отбрасываем — список исключений это лишь запасной пояс
/// от петли, главный пояс это правило `process_path` для xray. А вот
/// испорченный порт или режим — уже ошибка: молча подставлять умолчание значит
/// поднять туннель не тем, чем просили.
public func validate(_ raw: Any) throws -> SingboxParams {
    guard let params = raw as? [String: Any] else {
        throw ValidationError("параметры должны быть объектом, пришло \(raw)")
    }

    let socksPort = try port(params["socks_port"])

    let rawMode = params["split_mode"] ?? SplitMode.off.rawValue
    guard let modeString = rawMode as? String, let splitMode = SplitMode(rawValue: modeString) else {
        throw ValidationError("неизвестный режим раздельного туннеля: \(rawMode)")
    }

    let rawApps = params["split_apps"] ?? []
    guard let appList = rawApps as? [Any] else {
        throw ValidationError("split_apps должен быть списком")
    }
    let splitApps = try appList.map(appName)

    let rawStack = params["stack"] ?? Stack.gvisor.rawValue
    guard let stackString = rawStack as? String, let stack = Stack(rawValue: stackString) else {
        throw ValidationError("неизвестный сетевой стек: \(rawStack)")
    }

    let rawIPs = params["exclude_ips"] ?? []
    guard let ipList = rawIPs as? [Any] else {
        throw ValidationError("exclude_ips должен быть списком")
    }
    // Не строка — не адрес, тихо отбрасываем, как и любой другой мусор в этом
    // списке. Тип проверяем явно: число тоже описывает адрес, и молча принять
    // его значило бы собрать запасной пояс из выдуманных адресов.
    let excludeIPs = ipList.compactMap { value -> String? in
        guard !isBoolean(value), let text = value as? String else { return nil }
        return normalizedIPAddress(text)
    }

    let rawLevel = params["log_level"] as? String ?? ""
    let logLevel = knownLogLevels.contains(rawLevel) ? rawLevel : "warn"

    return SingboxParams(socksPort: socksPort, splitMode: splitMode, splitApps: splitApps,
                         stack: stack, excludeIPs: excludeIPs, logLevel: logLevel)
}

/// Каноническая запись адреса, или `nil`, если это не адрес.
///
/// Через `inet_pton`/`inet_ntop`, а не разбором строки: они дают ровно ту же
/// нормализацию, что `str(ipaddress.ip_address(...))` в Python, — сжатый
/// нижний регистр для IPv6 и отказ на всём, что адресом не является.
public func normalizedIPAddress(_ text: String) -> String? {
    var v4 = in_addr()
    if inet_pton(AF_INET, text, &v4) == 1 {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &v4, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, text, &v6) == 1 {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }
    return nil
}

/// Версия адреса: 4 или 6. Вызывать только на том, что прошло
/// `normalizedIPAddress`.
public func ipVersion(_ text: String) -> Int {
    var v4 = in_addr()
    return inet_pton(AF_INET, text, &v4) == 1 ? 4 : 6
}
