import Foundation
import NetworkExtension
#if canImport(Tun2SocksKit)
import Tun2SocksKit
#endif

/// Мост TUN ↔ SOCKS поверх `hev-socks5-tunnel` — та же библиотека, что уже
/// стоит на Android.
enum TunnelBridge {

    enum Failure: Error, CustomStringConvertible {
        case notLinked
        case noDescriptor
        var description: String {
            switch self {
            case .notLinked: return "мост TUN↔SOCKS не собран: нет Tun2SocksKit"
            case .noDescriptor: return "система не отдала дескриптор туннеля"
            }
        }
    }

    /// Конфиг моста — дословно тот же YAML, что собирает `ScVpnService.kt`,
    /// плюс потолки на память: значения по умолчанию рассчитаны на десктоп и в
    /// лимит расширения (50 МБ) вместе с Go-runtime ядра не помещаются.
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

    #if canImport(Tun2SocksKit)
    private static var configURL: URL?

    static func start(socksPort: Int, mtu: Int, tunAddress: String,
                      packetFlow: NEPacketTunnelFlow) throws {
        // Библиотека читает конфиг файлом, поэтому он кладётся во временную
        // папку расширения и удаляется при остановке.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hev-socks5.yml")
        try yaml(socksPort: socksPort, mtu: mtu, tunAddress: tunAddress)
            .write(to: url, atomically: true, encoding: .utf8)
        configURL = url

        // Дескриптор туннеля библиотека находит сама, перебирая сокеты
        // процесса: публичного пути к нему у NEPacketTunnelFlow нет.
        Socks5Tunnel.run(withConfig: .file(path: url)) { code in
            // Колбэк приходит, когда мост завершился. Ноль — штатная остановка.
            if code != 0 {
                NSLog("[SCVPN] мост TUN↔SOCKS завершился с кодом \(code)")
            }
        }
    }

    static func stop() {
        Socks5Tunnel.quit()
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
        configURL = nil
    }

    static func stats() -> (up: UInt64, down: UInt64) {
        let stats = Socks5Tunnel.stats
        return (UInt64(stats.up.bytes), UInt64(stats.down.bytes))
    }
    #else
    static func start(socksPort: Int, mtu: Int, tunAddress: String,
                      packetFlow: NEPacketTunnelFlow) throws {
        throw Failure.notLinked
    }

    static func stop() {}

    static func stats() -> (up: UInt64, down: UInt64) { (0, 0) }
    #endif
}
