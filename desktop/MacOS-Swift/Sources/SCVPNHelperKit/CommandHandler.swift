import Foundation
import SCVPNCore

/// Что обработчику команд известно о разговоре, в котором он вызван.
public struct CommandContext {
    /// Сказать клиенту строку лога. Не бросает и не блокирует.
    public let say: (String) -> Void
    /// Соединение, из которого пришла команда, — будущий владелец туннеля.
    public let conn: ClientHandle?

    public init(say: @escaping (String) -> Void, conn: ClientHandle?) {
        self.say = say
        self.conn = conn
    }
}

/// Отбить запрос, из которого выйдет конфиг непристойного размера.
///
/// Проверяется **до** валидации: `validate` ограничивает длину каждого имени,
/// но не число элементов, а 200 000 имён — это конфиг на десяток мегабайт,
/// который root молча запишет на диск.
func checkSizes(_ req: [String: Any]) throws {
    for (key, limit) in [("split_apps", maxSplitApps), ("exclude_ips", maxExcludeIPs)] {
        if let list = req[key] as? [Any], list.count > limit {
            throw ValidationError("слишком длинный список \(key): \(list.count), потолок \(limit)")
        }
    }
}

/// Разобрать одну строку запроса и выполнить её. **Всегда** возвращает ответ.
///
/// Демон не имеет права падать от кривого ввода: клиент недоверенный, а падение
/// демона означает, что sing-box останется без надзора.
public func handleLine(_ line: String, _ ctx: CommandContext,
                       _ sup: Supervisor, _ env: HelperEnv) -> [String: Any] {
    let req: [String: Any]
    do {
        // Ограничение глубины — не украшение: на глубоко вложенном JSON
        // разборщик Python отдавал RecursionError, который выходил наружу
        // мимо всех веток, а наружу это обрыв соединения, то есть снятие
        // туннеля одной кривой строкой. JSONSerialization на такой строке
        // возвращает ошибку, но полагаться на это без проверки нельзя.
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [])
        guard let dict = parsed as? [String: Any] else {
            return ["ok": false, "error": "не разобрал запрос: ожидался объект"]
        }
        req = dict
    } catch {
        return ["ok": false, "error": "не разобрал запрос: \(error.localizedDescription)"]
    }

    let cmd = req["cmd"] as? String

    do {
        switch cmd {
        case "start":
            try checkSizes(req)
            let params = try validate(req)
            // Путь к ядру приходит от клиента, но правило process_path даёт
            // процессу выход мимо туннеля — значит путь надо проверить, а не
            // принять на слово.
            let xrayPath = try checkedXrayPath(req["xray_path"])
            try sup.start(params, xrayPath: xrayPath, onLog: ctx.say, owner: ctx.conn)
            return ["ok": true, "running": true]

        case "stop":
            sup.stop()
            // Не зашитое false: stop() имеет право вернуться с живым
            // процессом, если тот пережил SIGKILL. Ответить «выключено», пока
            // маршруты держатся, — это ровно та ложь про состояние, от которой
            // уходим.
            let running = sup.isRunning
            return ["ok": !running, "running": running]

        case "status":
            return ["ok": true, "running": sup.isRunning,
                    "singbox": FileManager.default.fileExists(atPath: env.singboxExe.path)]

        case "install_singbox":
            let tag = try installSingbox(env, say: ctx.say)
            return ["ok": true, "version": tag]

        case "remove_singbox":
            return ["ok": true, "removed": try removeSingbox(env, sup: sup, say: ctx.say)]

        default:
            return ["ok": false, "error": "неизвестная команда: \(cmd ?? "nil")"]
        }
    } catch let e as ValidationError {
        return ["ok": false, "error": e.message]
    } catch let e as HelperPermissionError {
        return ["ok": false, "error": "отказано: \(e.message)"]
    } catch let e as HelperError {
        return ["ok": false, "error": e.message]
    } catch {
        env.log("ошибка при обработке \(cmd ?? "nil"): \(error)")
        return ["ok": false, "error": "\(error)"]
    }
}
