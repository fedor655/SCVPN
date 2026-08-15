import Foundation
import NetworkExtension

/// Мост TUN ↔ SOCKS поверх `hev-socks5-tunnel` — та же библиотека, что уже
/// стоит на Android.
///
/// Пакет `Tun2SocksKit` в сборке не подключён, пока нет ядра: без Xray мосту
/// некуда отдавать соединения. Поэтому здесь заглушка, которая честно
/// отказывается, а не делает вид, что туннель поднят.
enum TunnelBridge {

    enum Failure: Error, CustomStringConvertible {
        case notLinked
        var description: String {
            "мост TUN↔SOCKS не собран: нет Tun2SocksKit и ядра Xray"
        }
    }

    /// Конфиг моста — дословно тот же YAML, что собирает `ScVpnService.kt`,
    /// плюс потолки на память: значения по умолчанию рассчитаны на десктоп и в
    /// лимит расширения вместе с Go-runtime ядра не помещаются.
    static func yaml(socksPort: Int, mtu: Int, tunAddress: String) -> String {
        """
        tunnel:
          mtu: \(mtu)
          ipv4: \(tunAddress)
        socks5:
          port: \(socksPort)
          address: 127.0.0.1
          udp: 'udp'
        misc:
          task-stack-size: 20480
          tcp-buffer-size: 4096
          connect-timeout: 5000
          read-write-timeout: 60000
          log-level: warn
        """
    }

    static func start(socksPort: Int, mtu: Int, tunAddress: String,
                      packetFlow: NEPacketTunnelFlow) throws {
        throw Failure.notLinked
    }

    static func stop() {}

    static func stats() -> (up: UInt64, down: UInt64) { (0, 0) }
}
