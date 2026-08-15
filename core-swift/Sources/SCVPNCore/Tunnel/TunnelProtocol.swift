#if os(iOS)
import Foundation

/// Единственный канал доставки настроек в расширение туннеля.
///
/// App Group — платная capability, поэтому конфиг едет в
/// `NETunnelProviderProtocol.providerConfiguration`: приложение кладёт словарь
/// в профиль VPN, система отдаёт его расширению при старте. Ограничение одно —
/// значения обязаны быть property-list-типами, иначе система теряет их молча,
/// и на той стороне это выглядит как «расширение не видит конфига».
public struct TunnelConfig: Equatable {
    public var xrayConfigJSON: String
    public var socksPort: Int
    public var mtu: Int
    public var tunAddress: String
    public var serverName: String
    public var logLevel: String

    public init(xrayConfigJSON: String, socksPort: Int = defaultSocksPort,
                mtu: Int = 1500, tunAddress: String = "26.26.26.1",
                serverName: String = "", logLevel: String = "warning") {
        self.xrayConfigJSON = xrayConfigJSON
        self.socksPort = socksPort
        self.mtu = mtu
        self.tunAddress = tunAddress
        self.serverName = serverName
        self.logLevel = logLevel
    }

    public func asProviderConfiguration() -> [String: Any] {
        [
            "config": xrayConfigJSON,
            "socksPort": socksPort,
            "mtu": mtu,
            "tunAddress": tunAddress,
            "serverName": serverName,
            "logLevel": logLevel,
        ]
    }

    public init(providerConfiguration raw: [String: Any]) throws {
        func str(_ k: String) throws -> String {
            guard let v = raw[k] as? String else { throw TunnelConfigError.missing(k) }
            return v
        }
        func int(_ k: String) throws -> Int {
            guard let v = raw[k] as? Int else { throw TunnelConfigError.missing(k) }
            return v
        }
        self.init(xrayConfigJSON: try str("config"), socksPort: try int("socksPort"),
                  mtu: try int("mtu"), tunAddress: try str("tunAddress"),
                  serverName: try str("serverName"), logLevel: try str("logLevel"))
    }
}

public enum TunnelConfigError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    public var description: String {
        switch self {
        case .missing(let k): return "в настройках туннеля нет поля «\(k)»"
        }
    }
}

/// Запрос приложения к расширению.
public enum ProviderRequest: String, Codable {
    case status
}

/// Ответ расширения: статус, счётчики и хвост лога разом.
///
/// Отдельного запроса за логом нет намеренно: сотня строк дешевле лишнего
/// круга сообщений, а расширение всё равно отвечает целиком.
public struct ProviderStatus: Codable, Equatable {
    public var running: Bool
    public var since: Double?          // systemUptime старта, не дата
    public var up: UInt64
    public var down: UInt64
    public var lines: [String]

    public init(running: Bool, since: Double? = nil, up: UInt64 = 0,
                down: UInt64 = 0, lines: [String] = []) {
        self.running = running; self.since = since
        self.up = up; self.down = down; self.lines = lines
    }
}
#endif
