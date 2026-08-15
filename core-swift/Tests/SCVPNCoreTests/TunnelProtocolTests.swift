#if os(iOS)
import XCTest
@testable import SCVPNCore

/// Конфиг едет в расширение через системное хранилище настроек VPN, и оно
/// молча теряет всё, что не property-list. Проверяется здесь, потому что на
/// той стороне потеря выглядит как «расширение не видит конфига».
final class TunnelProtocolTests: XCTestCase {

    private func sample() -> TunnelConfig {
        TunnelConfig(xrayConfigJSON: #"{"outbounds":[]}"#, socksPort: 10808,
                     mtu: 1500, tunAddress: "26.26.26.1",
                     serverName: "Сервер 🇳🇱", logLevel: "warning")
    }

    func test_round_trip_keeps_every_field() throws {
        let restored = try TunnelConfig(providerConfiguration: sample().asProviderConfiguration())
        XCTAssertEqual(restored, sample())
    }

    func test_provider_configuration_holds_only_plist_types() {
        for (key, value) in sample().asProviderConfiguration() {
            XCTAssertTrue(value is String || value is NSNumber,
                          "поле \(key) не plist-типа: \(type(of: value))")
        }
    }

    func test_missing_field_is_a_named_error() {
        var raw = sample().asProviderConfiguration()
        raw.removeValue(forKey: "config")
        XCTAssertThrowsError(try TunnelConfig(providerConfiguration: raw)) { error in
            XCTAssertEqual(error as? TunnelConfigError, .missing("config"))
        }
    }

    func test_unicode_name_survives_the_system_store() throws {
        let restored = try TunnelConfig(providerConfiguration: sample().asProviderConfiguration())
        XCTAssertEqual(restored.serverName, "Сервер 🇳🇱")
    }

    func test_status_round_trip() throws {
        let status = ProviderStatus(running: true, since: 12.5, up: 1024, down: 2048,
                                    lines: ["[+] Туннель поднят"])
        let back = try JSONDecoder().decode(ProviderStatus.self,
                                            from: try JSONEncoder().encode(status))
        XCTAssertEqual(back, status)
    }
}
#endif
