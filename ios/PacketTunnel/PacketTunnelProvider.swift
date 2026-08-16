import NetworkExtension
import SCVPNCore
import os

/// Расширение туннеля: TUN → мост → Xray → сервер.
///
/// Порядок подъёма значим и обратный при остановке. **Ошибка на любом шаге
/// снимает всё предыдущее**: половина поднятого туннеля выглядит как «интернета
/// нет и выключить нечем», это хуже, чем отсутствие туннеля.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = RingLog()
    private var startedAt: Double?

    override func startTunnel(options: [String: NSObject]?) async throws {
        let raw = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration ?? [:]
        let config = try TunnelConfig(providerConfiguration: raw)
        log.append("[*] Подключаюсь к «\(config.serverName)»")

        // Порядок и откат живут в TunnelBringUp: их проверяют на подделках, а
        // здесь остаются только настоящие ядро, система и мост.
        try await sequence(for: config).run()

        startedAt = ProcessInfo.processInfo.systemUptime
        log.append("[+] Туннель поднят")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.append("[*] Останавливаюсь: причина \(reason.rawValue)")
        await sequence(for: nil).stop()
        startedAt = nil
    }

    /// Шаги подъёма для этого конфига. `nil` — только для остановки.
    private func sequence(for config: TunnelConfig?) -> TunnelBringUp {
        TunnelBringUp(
            startCore: {
                guard let config else { return }
                try XrayBridge.start(configJSON: config.xrayConfigJSON)
            },
            applySettings: { [weak self] in
                guard let self, let config else { return }
                try await self.setTunnelNetworkSettings(Self.settings(config))
            },
            startBridge: { [weak self] in
                guard let self, let config else { return }
                try TunnelBridge.start(socksPort: config.socksPort, mtu: config.mtu,
                                       tunAddress: config.tunAddress, packetFlow: self.packetFlow)
            },
            stopCore: { XrayBridge.stop() },
            clearSettings: { [weak self] in
                try? await self?.setTunnelNetworkSettings(nil)
            },
            stopBridge: { TunnelBridge.stop() }
        )
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let request = try? JSONDecoder().decode(ProviderRequest.self, from: messageData),
              request == .status else { return nil }
        let stats = TunnelBridge.stats()
        let status = ProviderStatus(running: startedAt != nil, since: startedAt,
                                    up: stats.up, down: stats.down, lines: log.snapshot())
        return try? JSONEncoder().encode(status)
    }

    private static func settings(_ config: TunnelConfig) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.tunAddress)
        let ipv4 = NEIPv4Settings(addresses: [config.tunAddress], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: config.mtu)
        // DNS те же, что на Android: резолв всё равно идёт через ядро, поэтому
        // важен сам факт перехвата запросов, а не конкретные адреса.
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        return settings
    }
}
