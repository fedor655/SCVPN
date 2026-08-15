import CryptoKit
import Foundation
import IOKit

/// Соль, чтобы наружу уходил не сам идентификатор платы, а необратимая
/// производная.
///
/// **Не менять ни соль, ни формат результата.** Значение уходит панели как
/// `x-hwid`, и его смена означает новый слот в лимите устройств у каждого
/// пользователя разом. Соль та же, что на Windows и Android, но исходник другой
/// (`IOPlatformUUID`), так что один человек с Мака и с ПК займёт два слота —
/// это верно, это разные устройства.
private let hwidSalt = "scvpn-hwid-v1"

/// Что-нибудь стабильное и уникальное для этой машины.
///
/// `IOPlatformUUID` выдаётся плате и переживает переустановку системы — ровно
/// то, что нужно, чтобы не занимать новый слот в лимите устройств. Через IOKit
/// напрямую, а не разбором вывода `ioreg`: тот же ответ без запуска процесса и
/// без регулярного выражения по чужому формату.
func machineSource() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPlatformExpertDevice"))
    if service != 0 {
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
                                                      kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !uuid.isEmpty {
            return uuid
        }
    }
    // Запасной вариант — MAC-адрес. Хуже (меняется с сетевой картой), но лучше
    // случайного значения: то пережило бы только текущую установку.
    return "mac-\(macAddressHex())"
}

private func macAddressHex() -> String {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let head = addrs else { return "000000000000" }
    defer { freeifaddrs(head) }

    var current: UnsafeMutablePointer<ifaddrs>? = head
    while let entry = current {
        defer { current = entry.pointee.ifa_next }
        guard String(cString: entry.pointee.ifa_name) == "en0",
              let sa = entry.pointee.ifa_addr,
              sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
        // sdl_data — это имя интерфейса, сразу за ним адрес длиной sdl_alen.
        // Читаем сырыми байтами: смещение поля-кортежа в Swift не берётся.
        let mac: [UInt8] = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
            guard dl.pointee.sdl_alen == 6 else { return [] }
            var copy = dl.pointee.sdl_data
            return withUnsafeBytes(of: &copy) { raw in
                let start = Int(dl.pointee.sdl_nlen)
                guard start + 6 <= raw.count else { return [] }
                return (0..<6).map { raw[start + $0] }
            }
        }
        if mac.count == 6 {
            return mac.map { String(format: "%02x", $0) }.joined()
        }
    }
    return "000000000000"
}

/// Стабильный HWID этого устройства. Считается один раз и запоминается.
///
/// Значение кладётся в `settings.json` и дальше берётся оттуда — даже если
/// система переустановлена.
public func deviceID() -> String {
    var settings = loadSettings()
    if let saved = settings["hwid"]?.stringValue, !saved.isEmpty {
        return saved
    }

    let digest = SHA256.hash(data: Data("\(hwidSalt):\(machineSource())".utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    // Формат UUID — панели его ожидают чаще всего и точно принимают.
    let hwid = [hex.prefix(8),
                hex.dropFirst(8).prefix(4),
                hex.dropFirst(12).prefix(4),
                hex.dropFirst(16).prefix(4),
                hex.dropFirst(20).prefix(12)].joined(separator: "-")

    settings["hwid"] = .string(hwid)
    saveSettings(settings)
    return hwid
}

/// Заголовки, которых ждут панели с учётом устройств.
///
/// Без них подписка с привязкой к устройствам отдаёт не серверы, а заглушку
/// `vless://0000…@0.0.0.0:1#App not supported`.
public func deviceHeaders() -> [String: String] {
    // Ровно четыре заголовка, ровно те же имена и источники, что в Python.
    // Лишний заголовок — это изменение того, что видит панель, а панели по
    // набору заголовков решают, отдавать ли серверы вообще.
    let host = ProcessInfo.processInfo.hostName
    return [
        "x-hwid": deviceID(),
        "x-device-os": "Darwin",
        // platform.release() в Python — это версия ядра Darwin, а не macOS.
        "x-ver-os": darwinRelease(),
        "x-device-model": host.isEmpty ? "Mac" : host,
    ]
}

private func darwinRelease() -> String {
    var info = utsname()
    guard uname(&info) == 0 else { return "" }
    return withUnsafeBytes(of: &info.release) { raw in
        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}
