import Foundation
import ServiceManagement

/// Состояние системного компонента с точки зрения пользователя.
///
/// Сегодняшний Python отвечал «ok» либо «failed», а сценарий трёхшаговый:
/// попросили — пользователь ушёл в настройки — вернулись и проверили. Это не
/// деталь реализации, а видимое пользователю поведение: показать «не удалось»
/// там, где система ждёт согласия, значит отправить его в тупик на самом
/// частом первом включении TUN.
public enum HelperState: Equatable {
    /// Регистрации ещё не было.
    case notInstalled
    /// Ждём пользователя в System Settings → Login Items.
    case awaitingApproval
    /// Готов к работе.
    case ready
    /// Не сложилось, и вот почему.
    case failed(String)

    public init(from status: SMAppService.Status) {
        switch status {
        case .notRegistered:    self = .notInstalled
        case .enabled:          self = .ready
        case .requiresApproval: self = .awaitingApproval
        case .notFound:
            // plist внутри бандла система не нашла. Это не «пользователь ещё
            // не согласился», а сломанная сборка: либо файла нет, либо его имя
            // разошлось с Label.
            self = .failed("plist системного компонента не найден в бандле")
        @unknown default:       self = .failed("неизвестный статус (\(status.rawValue))")
        }
    }
}

/// Версия демона, зашитая в сборку.
///
/// Нужна потому, что Фаза 0 показала: подменённый на месте бандл launchd не
/// подхватывает — ни новый бинарник, ни изменённый plist. Служба при этом
/// вообще перестаёт подниматься. Поэтому при несовпадении версии
/// перерегистрируемся, а не надеемся, что система заметит сама.
///
/// **Поднимать при каждом изменении демона или его plist.**
public let helperVersion = 1

public enum HelperInstaller {
    static let plistName = "\(Paths.helperLabel).plist"

    public static var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    public static func state() -> HelperState {
        HelperState(from: service.status)
    }

    /// Как истолковать исход `register()`.
    ///
    /// Вынесено чистой функцией: сам `SMAppService` требует бандла и в
    /// проверках недоступен, а решение «ошибка это или шаг сценария» — ровно
    /// то, что ошибиться легче всего.
    ///
    /// **Первый `register()` штатно возвращает ошибку** `SMAppServiceErrorDomain
    /// code=1 «Operation not permitted»` и переводит службу в
    /// `requiresApproval`. Это не сбой, а нормальный шаг: система plist нашла и
    /// приняла, ей нужно согласие пользователя (подтверждено экспериментом
    /// Фазы 0 — так вело себя всё четыре раза, из всех четырёх папок).
    public static func interpret(registerError: Error?, status: SMAppService.Status) -> HelperState {
        if let registerError {
            if status == .requiresApproval { return .awaitingApproval }
            if status == .enabled { return .ready }
            return .failed(registerError.localizedDescription)
        }
        return HelperState(from: status)
    }

    @discardableResult
    public static func register() -> HelperState {
        let svc = service
        var thrown: Error?
        do {
            try svc.register()
        } catch {
            thrown = error
        }
        return interpret(registerError: thrown, status: svc.status)
    }

    public static func unregister() throws {
        try service.unregister()
    }

    public static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Дождаться, пока пользователь согласится в System Settings.
    ///
    /// Опрос раз в секунду, а не подписка: уведомления о смене статуса
    /// `SMAppService` не шлёт, а окно настроек пользователь закрывает когда
    /// угодно.
    public static func waitUntilReady(timeout: TimeInterval = 120) -> HelperState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = state()
            if current == .ready { return current }
            if case .failed = current { return current }
            Thread.sleep(forTimeInterval: 1)
        }
        return state()
    }

    /// Привести компонент в рабочее состояние, переустановив при смене версии.
    ///
    /// Периодической сверки статуса здесь нет намеренно: Фаза 0 показала, что
    /// регистрация переживает перезагрузку и служба поднимается сама.
    ///
    /// А вот перерегистрация при несовпадении версии обязательна, и это условие
    /// корректности, а не оптимизация: `ExitTimeOut = 40` — расчёт худшего
    /// случая снятия, и служба, живущая со старым значением, получит SIGKILL на
    /// середине снятия, оставив `sing-box` сиротой с маршрутами.
    @discardableResult
    public static func ensureCurrent(forceReinstall: Bool = false) -> HelperState {
        var settings = loadSettings()
        let known = settings["helper_version"]?.intValue
        let current = state()

        // Служба готова, а версия просто не записана (первый запуск после
        // обновления приложения, либо пользователь разрешил её мимо этой
        // ветки). Это НЕ расхождение версий: перерегистрировать здесь значит
        // заново просить разрешение у человека, у которого всё уже работает.
        // Принимаем как есть и запоминаем.
        if current == .ready, known == nil, !forceReinstall {
            settings["helper_version"] = .int(helperVersion)
            saveSettings(settings)
            return .ready
        }

        if current == .ready, known == helperVersion, !forceReinstall {
            return .ready
        }

        // Версия действительно другая, либо просили переустановить.
        if current != .notInstalled {
            // Снимаем и ставим заново: подмену на месте система не замечает.
            try? unregister()
            // Даём launchd отпустить службу — иначе register() встанет поверх
            // ещё живой регистрации, ровно как launchctl bootstrap в Фазе 2.
            for _ in 0..<40 {
                if state() == .notInstalled { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        let result = register()
        if result == .ready {
            settings["helper_version"] = .int(helperVersion)
            saveSettings(settings)
        }
        return result
    }

    /// Можно ли прямо сейчас поднять TUN.
    public static func privileged() -> Bool {
        state() == .ready
    }
}
