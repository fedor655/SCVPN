import XCTest
@testable import SCVPNCore

/// Перенос профилей между платформами. Формат общий, а вот слияние с тем, что
/// уже лежит на устройстве, — место, где легко потерять чужие серверы.
final class ProfilesMergeTests: XCTestCase {

    private func server(_ name: String, uuid: String = "u") -> Server {
        Server(proto: "vless", name: name, address: "\(name).example", uuid: uuid)
    }

    func test_own_servers_are_added_not_replaced() {
        let mine = Profiles(servers: [server("моё")])
        let theirs = Profiles(servers: [server("чужое")])
        XCTAssertEqual(mergeProfiles(mine, theirs).servers.map(\.name), ["моё", "чужое"])
    }

    func test_same_server_under_another_name_is_not_duplicated() {
        let mine = Profiles(servers: [server("дом", uuid: "one")])
        var renamed = server("дом", uuid: "one"); renamed.name = "работа"
        XCTAssertEqual(mergeProfiles(mine, Profiles(servers: [renamed])).servers.count, 1)
    }

    func test_new_subscription_comes_with_its_servers() {
        let incoming = Profiles(subscriptions: [
            Subscription(name: "Панель", url: "https://p/sub", servers: [server("A")]),
        ])
        let merged = mergeProfiles(Profiles(), incoming)
        XCTAssertEqual(merged.subscriptions.count, 1)
        XCTAssertEqual(merged.allServers().map(\.name), ["A"])
    }

    func test_known_subscription_gets_its_server_list_replaced() {
        let mine = Profiles(subscriptions: [
            Subscription(url: "https://p/sub", servers: [server("старый")]),
        ])
        let incoming = Profiles(subscriptions: [
            Subscription(url: "https://p/sub", servers: [server("новый")]),
        ])
        let merged = mergeProfiles(mine, incoming)
        XCTAssertEqual(merged.subscriptions.count, 1)
        XCTAssertEqual(merged.subscriptions[0].servers.map(\.name), ["новый"])
    }

    func test_server_already_known_from_subscription_is_not_added_as_own() {
        let mine = Profiles(subscriptions: [
            Subscription(url: "https://p/sub", servers: [server("общий", uuid: "same")]),
        ])
        let incoming = Profiles(servers: [server("общий", uuid: "same")])
        XCTAssertTrue(mergeProfiles(mine, incoming).servers.isEmpty)
    }

    func test_file_round_trip_keeps_everything() throws {
        let profiles = Profiles(
            subscriptions: [Subscription(name: "Панель", url: "https://p/sub",
                                         servers: [server("A")])],
            servers: [server("своё")])
        let data = try JSONEncoder().encode(profiles)
        XCTAssertEqual(try JSONDecoder().decode(Profiles.self, from: data), profiles)
    }
}

/// Повторное добавление той же подписки — это обновление, а не вторая копия.
///
/// Проверка живёт рядом со слиянием профилей: правило одно и то же — подписка
/// опознаётся по ссылке.
final class SubscriptionIdentityTests: XCTestCase {

    func test_same_url_twice_is_one_subscription() {
        var profiles = Profiles(subscriptions: [
            Subscription(name: "Панель", url: "https://p/sub", servers: []),
        ])
        let incoming = Profiles(subscriptions: [
            Subscription(name: "Панель", url: "https://p/sub",
                         servers: [Server(proto: "vless", name: "A", address: "a", uuid: "u")]),
        ])
        let merged = mergeProfiles(profiles, incoming)
        XCTAssertEqual(merged.subscriptions.count, 1)
        XCTAssertEqual(merged.subscriptions[0].servers.count, 1)

        profiles = merged
        XCTAssertEqual(mergeProfiles(profiles, incoming).subscriptions.count, 1)
    }
}
