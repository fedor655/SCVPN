import Foundation

/// Снятие демона, оставшегося от Python-версии.
///
/// Пользователь, у которого стояла Python-версия, получает на диске
/// `/Library/LaunchDaemons/com.scvpn.helper.plist`, указывающий в никуда: под
/// `SMAppService` plist живёт внутри бандла, а прежний остаётся снаружи. launchd
/// с `KeepAlive` будет вечно перезапускать несуществующий путь.
///
/// Папку `/Library/Application Support/SCVPN/bin` **не трогаем**: там лежит
/// `sing-box`, который новому демону пригодится.
public enum LegacyHelper {
    public static let plistPath = "/Library/LaunchDaemons/\(Paths.helperLabel).plist"
    /// Код демона Python-версии. Под `SMAppService` он не нужен вовсе.
    public static let codeDir = "/Library/Application Support/SCVPN/code"

    public static let question = """
        Найден системный компонент от прежней версии SCVPN.

        Его нужно снять: он указывает на файлы, которых больше нет, и система \
        будет бесконечно пытаться его запустить. Понадобится пароль \
        администратора — один раз.

        Снять сейчас?
        """

    /// Есть ли что снимать.
    public static func present() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Шаги снятия. Отдельно от запуска, чтобы их можно было прочитать в
    /// проверке, не поднимая диалог пароля.
    public static func removalScript() -> String {
        [
            // bootout молча падает, если службы уже нет — отсюда || true. Он же
            // даёт шагу успешный код возврата, поэтому цепочка && им не рвётся.
            "launchctl bootout system/\(Paths.helperLabel) 2>/dev/null || true",
            "rm -f \(shellQuote(plistPath))",
            "rm -rf \(shellQuote(codeDir))",
        ].joined(separator: " && ")
    }

    /// Снять прежний компонент. Спросит пароль администратора — один раз.
    public static func remove() throws {
        guard present() else { return }
        try runAsAdmin(script: removalScript(),
                       prompt: "SCVPN удаляет системный компонент прежней версии")
    }
}

/// Экранировать строку для одинарных кавычек оболочки.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Экранировать строку в строковый литерал AppleScript.
///
/// `JSONSerialization` для этого не годится, хотя выглядит подходяще: JSON и
/// AppleScript совпадают только на `\\`, `\"`, `\n`, `\r`, `\t`. Не-ASCII JSON
/// уводит в `\uXXXX`, а такую последовательность AppleScript не компилирует
/// вовсе — синтаксическая ошибка на пустом месте. Приглашение здесь русское,
/// поэтому на этом падала бы **каждая** установка, не показав даже диалога.
/// Не-ASCII просто не трогаем: `osascript` читает `-e` в UTF-8.
func appleScriptLiteral(_ s: String) -> String {
    var out = s.replacingOccurrences(of: "\\", with: "\\\\")
    out = out.replacingOccurrences(of: "\"", with: "\\\"")
    out = out.replacingOccurrences(of: "\n", with: "\\n")
    out = out.replacingOccurrences(of: "\r", with: "\\r")
    out = out.replacingOccurrences(of: "\t", with: "\\t")
    return "\"" + out + "\""
}

/// Текст `do shell script …` одним системным диалогом.
///
/// Вынесено отдельно, чтобы саму сборку строки можно было проверить настоящим
/// `osascript` без повышения прав: убрав `with administrator privileges`,
/// остаток компилируется и выполняется как обычный пользователь — значит и
/// компилируемость, и содержимое литералов проверяются тем же кодом, которым
/// пользуется `remove()`.
func doShellScriptCommand(script: String, prompt: String) -> String {
    "do shell script \(appleScriptLiteral(script)) with prompt \(appleScriptLiteral(prompt)) "
        + "with administrator privileges"
}

/// Выполнить shell-скрипт от администратора одним системным диалогом.
func runAsAdmin(script: String, prompt: String) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", doShellScriptCommand(script: script, prompt: prompt)]
    let err = Pipe()
    proc.standardError = err
    proc.standardOutput = Pipe()
    try proc.run()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus != 0 else { return }

    let text = String(decoding: errData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if text.contains("User canceled") || text.contains("-128") {
        throw ValidationError("Отменено.")
    }
    throw ValidationError(text.isEmpty ? "не удалось выполнить операцию" : text)
}
