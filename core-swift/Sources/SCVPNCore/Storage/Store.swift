import Foundation

/// Настройки по умолчанию. Значения и имена ключей — дословно из
/// `shared/storage.py:103`; расхождение сломало бы чтение существующего
/// `settings.json` у пользователя.
public let defaultSettings: [String: JSONValue] = [
    "socks_port": .int(10808),
    "http_port": .int(10809),
    "route_mode": .string("global"),      // global | bypass_ru
    "block_ads": .bool(false),
    "system_proxy": .bool(true),          // включать системный прокси в режиме proxy
    "selected_key": .string(""),          // Server.key() выбранного сервера
    "tls_fingerprint": .string("auto"),   // auto = автоподбор, либо chrome/firefox/…
    "vpn_mode": .string("proxy"),         // proxy = системный прокси, tun = весь трафик
    "split_mode": .string("off"),         // off | exclude | include, только TUN
    "split_apps": .array([]),
    "tun_stack": .string("gvisor"),       // сетевой стек sing-box в TUN
]

/// Прочитать настройки, дополнив умолчаниями.
///
/// **Словарь, а не структура** — и это не лень. Ключ `hwid` пишет в
/// `settings.json` отдельный модуль, и в `defaultSettings` его нет; структура с
/// фиксированными полями потеряла бы его при первом же сохранении, а
/// пользователь занял бы новый слот в лимите устройств панели. Неизвестные
/// ключи обязаны переживать круг чтение-запись.
public func loadSettings() -> [String: JSONValue] {
    var settings = defaultSettings
    guard let data = try? Data(contentsOf: Paths.settingsFile) else { return settings }
    guard let loaded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
        // Испорченный файл — не повод падать: пользователь имеет право открыть
        // его редактором, и сломанный JSON не должен запирать приложение.
        FileHandle.standardError.write(Data("[storage] не смог прочитать настройки\n".utf8))
        return settings
    }
    for (k, v) in loaded { settings[k] = v }
    return settings
}

public func saveSettings(_ settings: [String: JSONValue]) {
    Paths.ensureDirs()
    write(settings, to: Paths.settingsFile)
}

public func loadProfiles() -> Profiles {
    guard let data = try? Data(contentsOf: Paths.profilesFile) else { return Profiles() }
    do {
        return try JSONDecoder().decode(Profiles.self, from: data)
    } catch {
        FileHandle.standardError.write(Data("[storage] не смог прочитать профили: \(error)\n".utf8))
        return Profiles()
    }
}

public func saveProfiles(_ profiles: Profiles) {
    Paths.ensureDirs()
    write(profiles, to: Paths.profilesFile)
}

/// Записать JSON так же, как это делал Python: с отступом в 2 и без
/// экранирования не-ASCII и косых черт.
///
/// Формат на диске заморожен: файлы открывают текстовым редактором, и
/// превращение русских имён серверов в `\uXXXX` — это поломка, пусть и не
/// ломающая разбор.
func write<T: Encodable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    guard let data = try? encoder.encode(value) else {
        FileHandle.standardError.write(Data("[storage] не смог записать \(url.lastPathComponent)\n".utf8))
        return
    }
    try? data.write(to: url, options: .atomic)
}

/// Отметка времени в том же виде, что пишет Python: `2026-08-15 17:42`.
public func nowISO() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date())
}
