#if os(iOS)
import Foundation

/// Порядок подъёма и снятия туннеля.
///
/// Вынесен отдельным типом, а не написан внутри `PacketTunnelProvider`, по
/// одной причине: `NEPacketTunnelProvider` в проверках не создать, а порядок —
/// именно то место, где ошибка стоит дороже всего. **Ошибка на любом шаге
/// снимает всё предыдущее**: половина поднятого туннеля выглядит как «интернета
/// нет и выключить нечем», это хуже, чем отсутствие туннеля.
///
/// Шаги передаются замыканиями, поэтому проверки подставляют подделки, а
/// расширение — настоящие ядро, систему и мост.
public struct TunnelBringUp: Sendable {
    /// 1. Поднять ядро.
    public var startCore: @Sendable () throws -> Void
    /// 2. Отдать системе сетевые настройки и дождаться подтверждения.
    public var applySettings: @Sendable () async throws -> Void
    /// 3. Завести мост TUN ↔ SOCKS.
    public var startBridge: @Sendable () throws -> Void

    /// Откат: погасить ядро.
    public var stopCore: @Sendable () -> Void
    /// Откат: снять сетевые настройки.
    ///
    /// Без этого система подержит маршруты на мёртвом туннеле до собственного
    /// таймаута — то есть у человека пропадёт сеть, хотя приложение уже сдалось.
    public var clearSettings: @Sendable () async -> Void
    /// Откат: остановить мост.
    public var stopBridge: @Sendable () -> Void

    public init(
        startCore: @escaping @Sendable () throws -> Void,
        applySettings: @escaping @Sendable () async throws -> Void,
        startBridge: @escaping @Sendable () throws -> Void,
        stopCore: @escaping @Sendable () -> Void,
        clearSettings: @escaping @Sendable () async -> Void,
        stopBridge: @escaping @Sendable () -> Void = {}
    ) {
        self.startCore = startCore
        self.applySettings = applySettings
        self.startBridge = startBridge
        self.stopCore = stopCore
        self.clearSettings = clearSettings
        self.stopBridge = stopBridge
    }

    /// Поднять туннель целиком. Бросает первую же ошибку, откатив сделанное.
    public func run() async throws {
        try startCore()
        do {
            try await applySettings()
        } catch {
            stopCore()
            throw error
        }
        do {
            try startBridge()
        } catch {
            await clearSettings()
            stopCore()
            throw error
        }
    }

    /// Снять туннель. Порядок обратный подъёму: сперва мост, потом ядро.
    ///
    /// Мост первым, потому что он держит дескриптор туннеля: погасив ядро
    /// раньше, мы получили бы мост, качающий пакеты в никуда.
    public func stop() async {
        stopBridge()
        stopCore()
    }
}
#endif
