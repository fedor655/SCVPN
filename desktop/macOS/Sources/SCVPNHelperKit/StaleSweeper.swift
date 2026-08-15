import Foundation

/// Экранировать строку для `pgrep -f` (POSIX ERE).
///
/// Не `NSRegularExpression.escapedPattern(for:)`: тот заворачивает строку в
/// `\Q…\E`, который понимает ICU и не понимает pgrep — шаблон уехал бы туда
/// буквально и не совпал ни с чем, то есть защита от сироты погасла бы молча.
/// Экранируем сами, как это делает `re.escape` в Python: всё, что не буква,
/// не цифра и не подчёркивание, — через обратную косую.
func escapedForPgrep(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        let safe = (ch.value < 128)
            && (CharacterSet.alphanumerics.contains(ch) || ch == "_")
        if !safe && ch.value < 128 { out.unicodeScalars.append("\\") }
        out.unicodeScalars.append(ch)
    }
    return out
}

/// Шаблон командной строки, которую составляем только мы.
///
/// Чужой процесс под неё не попадёт, а наш попадёт, даже если его успели
/// завернуть в оболочку.
func stalePattern(_ env: HelperEnv) -> String {
    escapedForPgrep("\(env.singboxExe.path) run -c \(env.configPath.path)")
}

/// PID-ы осиротевшего sing-box. `nil` — посмотреть не удалось.
///
/// Разница между «никого нет» и «не смог узнать» здесь решающая: на этот ответ
/// опирается запрет поднимать туннель поверх чужого sing-box. Молчаливое
/// «никого» при сломанном pgrep пустило бы второй поверх первого, поэтому
/// неизвестность — это не пустой список, а отказ.
public func stalePIDs(_ env: HelperEnv) -> [String]? {
    guard let r = env.procTool(["/usr/bin/pgrep", "-f", stalePattern(env)]),
          r.status == 0 || r.status == 1 else {
        return nil
    }
    return r.stdout.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

/// Снять sing-box, переживший прошлый запуск демона. `true` — чисто.
///
/// Обрыв клиента демон видит сам, а вот собственную смерть по `-9` — нет:
/// ручка на процесс вместе с демоном пропадает, а sing-box остаётся держать
/// маршруты. Это ровно та мёртвая сеть, ради которой всё затевалось, поэтому
/// новый демон начинает с чистого листа.
///
/// Ждём именно **смерти**, а не отправки сигнала. `pkill` возвращается сразу, и
/// рапорт об успехе при живой сироте означал бы второй sing-box рядом с первым,
/// дерущийся за default route. Поэтому: SIGTERM, ожидание, при неудаче SIGKILL,
/// и только по факту исчезновения — запись об успехе.
///
/// Не смогли посмотреть — отвечаем `false`, а не `true`. Неизвестность здесь
/// ничем не лучше живой сироты: решение по этому ответу принимается одно и то
/// же — поднимать туннель или нет.
@discardableResult
public func killStaleSingbox(_ env: HelperEnv) -> Bool {
    guard var left = stalePIDs(env) else {
        env.log("ТРЕВОГА: не смог проверить, остался ли sing-box от прошлого запуска — "
                + "считаю, что остался")
        return false
    }
    if left.isEmpty { return true }

    let pattern = stalePattern(env)
    for sig in ["-TERM", "-KILL"] {
        env.log("остался sing-box от прошлого запуска демона: \(left.joined(separator: " ")), шлю \(sig)")
        if env.procTool(["/usr/bin/pkill", sig, "-f", pattern]) == nil { return false }
        let deadline = Date().addingTimeInterval(env.sweepGrace)
        while Date() < deadline {
            guard let now = stalePIDs(env) else { return false }
            if now.isEmpty {
                env.log("осиротевший sing-box снят")
                return true
            }
            left = now
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    env.log("ТРЕВОГА: осиротевший sing-box не снялся: \(left.joined(separator: " ")) — "
            + "поднимать туннель поверх него нельзя, он держит маршруты")
    return false
}
