// Приложение-зонд для Фазы 0.
//
// Не GUI намеренно. `SMAppService` требует настоящего бандла, но не требует
// окна: запуск исполняемого файла прямо из `Contents/MacOS/` даёт правильный
// `Bundle.main`, и всё управление сводится к трём словам в терминале вместо
// кликов. Результат при этом ровно тот же, а переписать вывод в план можно
// копипастой.
import Foundation
import ServiceManagement

// Метка приезжает из probe-version.swift: у каждого места проверки своя
// личность, иначе BTM отвечает памятью о прежнем согласии, а не про папку.
let service = SMAppService.daemon(plistName: "\(probeLabel).plist")

func statusName(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered:    return "notRegistered — регистрации нет"
    case .enabled:          return "enabled — служба зарегистрирована и разрешена"
    case .requiresApproval: return "requiresApproval — ждём пользователя в System Settings"
    case .notFound:         return "notFound — plist в бандле не найден"
    @unknown default:       return "неизвестный статус (\(s.rawValue))"
    }
}

func report() {
    print("бандл:  \(Bundle.main.bundleURL.path)")
    print("служба: \(probeLabel)")
    print("версия: \(probeVersion)")
    print("статус: \(statusName(service.status)) [rawValue=\(service.status.rawValue)]")
}

let command = CommandLine.arguments.dropFirst().first ?? "status"

switch command {
case "status":
    report()

case "register":
    do {
        try service.register()
        print("register() вернулся без ошибки")
    } catch {
        // Первый register() штатно отдаёт SMAppServiceErrorDomain code=1 и
        // переводит службу в requiresApproval. Это не сбой, а шаг сценария:
        // система plist нашла и приняла, ей нужно согласие пользователя.
        print("register() бросил: \(error)")
        print("  (code=1 на первом вызове — ожидаемо, смотри статус ниже)")
    }
    report()
    if service.status == .requiresApproval {
        print("\nОткрываю System Settings → Login Items. Разреши «SMProbe» и запусти `status`.")
        SMAppService.openSystemSettingsLoginItems()
    }

case "unregister":
    do {
        try service.unregister()
        print("unregister() вернулся без ошибки")
    } catch {
        print("unregister() бросил: \(error)")
    }
    report()

case "settings":
    SMAppService.openSystemSettingsLoginItems()

default:
    print("""
    Команды: status | register | unregister | settings
    Запускать сам исполняемый файл внутри бандла, например:
      /Applications/SMProbe.app/Contents/MacOS/SMProbe status
    """)
    exit(2)
}
