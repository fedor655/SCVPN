import Foundation

/// Подписка — именованный URL плюс список серверов, полученных с него.
public struct Subscription: Codable, Equatable, Sendable {
    public var name: String = ""
    public var url: String = ""
    public var updated: String = ""
    public var added: String = ""           // когда подписку добавили в приложение
    /// Сведения от панели: срок, трафик, автообновление. Хранятся, чтобы экран
    /// подписки открывался мгновенно и работал без сети — цифры от последнего
    /// успешного обновления, дата этого обновления лежит в `info.fetched`.
    public var info: SubscriptionInfo = SubscriptionInfo()
    public var servers: [Server] = []

    public init(name: String = "", url: String = "", updated: String = "",
                added: String = "", info: SubscriptionInfo = SubscriptionInfo(),
                servers: [Server] = []) {
        self.name = name; self.url = url; self.updated = updated
        self.added = added; self.info = info; self.servers = servers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        name = str(.name); url = str(.url); updated = str(.updated); added = str(.added)
        info = (try? c.decode(SubscriptionInfo.self, forKey: .info)) ?? SubscriptionInfo()
        servers = (try? c.decode([Server].self, forKey: .servers)) ?? []
    }
}

/// Профили: подписки плюс одиночные серверы, добавленные ссылкой вручную.
public struct Profiles: Codable, Equatable, Sendable {
    public var subscriptions: [Subscription] = []
    public var servers: [Server] = []       // одиночные

    public init(subscriptions: [Subscription] = [], servers: [Server] = []) {
        self.subscriptions = subscriptions
        self.servers = servers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = (try? c.decode([Subscription].self, forKey: .subscriptions)) ?? []
        servers = (try? c.decode([Server].self, forKey: .servers)) ?? []
    }

    /// Одиночные серверы идут первыми, затем серверы подписок — порядок тот же,
    /// что в Python: по нему строится список на экране и работает
    /// `selected_key`.
    public func allServers() -> [Server] {
        servers + subscriptions.flatMap(\.servers)
    }
}
