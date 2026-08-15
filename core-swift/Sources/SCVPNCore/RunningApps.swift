import AppKit

/// Список запущенных приложений для правил раздельного туннелирования.
///
/// sing-box сопоставляет соединение с процессом-владельцем по имени
/// исполняемого файла — для macOS это файл **внутри** бандла, то есть
/// `Telegram.app` даёт имя `Telegram`, а не `Telegram.app`.
///
/// Берём только приложения из `/Applications`, `/System/Applications` и
/// `~/Applications`: в системе их под тысячу, и показывать пользователю
/// системные демоны бессмысленно. Расширения (`.appex` — виджеты, шаринг и
/// прочее) отбрасываем: это не то, что человек хочет выбрать в списке.
public enum RunningApps {

    public static let manualHint = "Имя приложения (например, Telegram):"

    static var appPrefixes: [String] {
        ["/Applications/", "/System/Applications/",
         FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path + "/"]
    }

    /// Имена запущенных приложений, без дубликатов, по алфавиту.
    ///
    /// Через `NSWorkspace`, а не разбор вывода `ps`: тот же ответ без запуска
    /// процесса, и приложения там уже отделены от демонов.
    public static func runningApps() -> [String] {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.executableURL else { continue }
            let path = url.path
            guard appPrefixes.contains(where: { path.hasPrefix($0) }) else { continue }
            guard !path.contains(".appex/") else { continue }
            let name = url.lastPathComponent
            if !name.isEmpty { names.insert(name) }
        }
        return names.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Привести введённое руками имя к виду, который поймёт правило sing-box.
    public static func normalizeAppName(_ s: String) -> String {
        var name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("/") { name.removeLast() }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.hasSuffix(".app") { name.removeLast(".app".count) }
        return name
    }
}
