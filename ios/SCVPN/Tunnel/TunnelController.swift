import Foundation
import NetworkExtension
import SCVPNCore

/// Профиль VPN и управление туннелем.
///
/// Состояние берётся у системы (`NEVPNStatusDidChange`), а не считается по
/// таймеру: кнопка обязана показывать то, что есть на самом деле, — свойство
/// Android-версии, которое здесь сохраняется.
@MainActor
final class TunnelController: ObservableObject {

    @Published private(set) var state: ConnectionState = .idle
    /// Последняя причина отказа — её показывает экран, а не молчаливый лог.
    @Published private(set) var lastError: String?

    /// Есть ли в бандле расширение туннеля.
    ///
    /// Сборка от бесплатного Apple ID собирается без него: entitlement
    /// `networkextension` таким аккаунтам не выдаётся. Без расширения система
    /// отказывает записать профиль VPN **молча** — никакого диалога не
    /// появляется, и совет «разреши в диалоге» отправляет искать несуществующее.
    static var hasTunnelExtension: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(
                  at: plugins, includingPropertiesForKeys: nil) else { return false }
        return items.contains { $0.pathExtension == "appex" }
    }

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            let status = connection.status
            Task { @MainActor in self?.state = ConnectionState(status) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Уже поставленный профиль, если он есть. Побочный эффект — обновление
    /// состояния: приложение могли открыть при уже поднятом туннеле.
    func refresh() async {
        guard let manager = try? await loadManager() else { return }
        state = ConnectionState(manager.connection.status)
    }

    private func loadManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        // Профиль ровно один. Лишние — мусор прошлых сборок: он мешает
        // пользователю в Настройках, поэтому удаляется, а не игнорируется.
        for extra in all.dropFirst() { try? await extra.removeFromPreferences() }
        let found = all.first ?? NETunnelProviderManager()
        manager = found
        return found
    }

    /// Поставить или обновить профиль. Первый вызов показывает системный
    /// запрос разрешения — это штатный шаг, а не ошибка.
    func install(config: TunnelConfig) async throws {
        let manager = try await loadManager()
        let proto = NETunnelProviderProtocol()
        // Поле обязательное, но адрес настоящего сервера живёт внутри конфига
        // ядра — сюда идёт имя, которое человек увидит в Настройках.
        proto.serverAddress = config.serverName.isEmpty ? "SCVPN" : config.serverName
        proto.providerBundleIdentifier = "com.scvpn.ios.PacketTunnel"
        proto.providerConfiguration = config.asProviderConfiguration()
        manager.protocolConfiguration = proto
        manager.localizedDescription = "SCVPN"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // Перечитать обязательно: сохранённый объект система помечает
        // устаревшим, и startVPNTunnel на нём отвечает configuration invalid.
        try await manager.loadFromPreferences()
    }

    func start(config: TunnelConfig) async throws {
        guard Self.hasTunnelExtension else { throw Failure.noExtension }
        try await install(config: config)
        let manager = try await loadManager()
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = Self.explain(error)
            throw error
        }
    }

    func stop() async {
        guard let manager = try? await loadManager() else { return }
        manager.connection.stopVPNTunnel()
    }

    /// Спросить расширение о состоянии: счётчики и хвост его лога.
    ///
    /// `nil` — расширение не запущено или не ответило. Это не ошибка: спросить
    /// выключенный туннель не о чем.
    func askStatus() async -> ProviderStatus? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected,
              let data = try? JSONEncoder().encode(ProviderRequest.status) else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { reply in
                    continuation.resume(returning: reply.flatMap {
                        try? JSONDecoder().decode(ProviderStatus.self, from: $0)
                    })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    enum Failure: Error {
        /// Сборка без расширения туннеля.
        case noExtension
    }

    /// Человеческое объяснение отказа NetworkExtension.
    ///
    /// Сырое `NEVPNError` пользователю не говорит ничего, а два случая из трёх
    /// — не поломка, а среда: симулятор туннели не поднимает вообще, и профиль
    /// без разрешения не ставится.
    static func explain(_ error: Error) -> String {
        if case Failure.noExtension = error {
            return """
                В этой сборке нет расширения туннеля, поэтому подключение \
                недоступно.

                Возможность поднимать VPN Apple не выдаёт бесплатным \
                аккаунтам: профиль с ней не подписывается. Остальное \
                работает — серверы, подписки, пинг, перенос профилей.
                """
        }
        #if targetEnvironment(simulator)
        return """
            В симуляторе VPN-туннель не поднимается: NetworkExtension там не \
            работает. Проверять туннель можно только на устройстве.
            """
        #else
        let nsError = error as NSError
        if nsError.domain == NEVPNErrorDomain,
           let code = NEVPNError.Code(rawValue: nsError.code) {
            switch code {
            case .configurationDisabled: return "Профиль VPN выключен в Настройках."
            case .configurationReadWriteFailed:
                // Диалог система показывает не всегда: если у сборки нет права
                // ставить VPN-профиль, она отказывает молча.
                return """
                    Система не дала записать профиль VPN.

                    Если запроса на разрешение не было — у этой сборки нет \
                    права ставить VPN-профиль.
                    """
            case .configurationInvalid: return "Профиль VPN собран неверно."
            case .configurationStale: return "Профиль VPN устарел, попробуй ещё раз."
            case .connectionFailed: return "Туннель не поднялся."
            default: break
            }
        }
        return "\(error.localizedDescription)"
        #endif
    }
}
