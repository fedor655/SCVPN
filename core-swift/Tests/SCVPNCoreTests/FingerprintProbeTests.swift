import XCTest
@testable import SCVPNCore

/// Автоподбор отпечатка на подделке замерщика.
///
/// Живая проба поднимает ядро и ходит в сеть, поэтому раньше порядок кандидатов
/// проверялся только руками. С протоколом `DelayMeasuring` он проверяется здесь.
final class FingerprintProbeTests: XCTestCase {

    /// Отвечает только на конфиг с нужным отпечатком.
    ///
    /// Отпечаток вытаскивается из самого конфига, а не из аргумента: так
    /// проверяется, что подбор его туда действительно кладёт.
    private struct FakeMeasurer: DelayMeasuring {
        let working: String
        func measure(configJSON: String, url: String) -> Int {
            configJSON.contains("\"fingerprint\":\"\(working)\"") ? 42 : -1
        }
    }

    private func reality() -> Server {
        Server(proto: "vless", address: "a.b", port: 443, uuid: "u",
               network: "tcp", security: "reality", publicKey: "pk", shortID: "sid")
    }

    func test_candidate_order_is_frozen() {
        XCTAssertEqual(candidateFingerprints(reality(), override: "auto"),
                       ["firefox", "chrome", "safari", "edge", "ios", "randomized"])
    }

    func test_subscription_fingerprint_goes_first() {
        var s = reality(); s.fingerprint = "chrome"
        XCTAssertEqual(candidateFingerprints(s, override: "auto").first, "chrome")
    }

    func test_randomized_from_subscription_is_not_a_choice() {
        var s = reality(); s.fingerprint = "randomized"
        XCTAssertEqual(candidateFingerprints(s, override: "auto").first, "firefox")
    }

    func test_explicit_override_is_not_probed() {
        var s = reality(); s.fingerprint = "chrome"
        XCTAssertEqual(findWorkingFingerprint(s, override: "safari",
                                              using: FakeMeasurer(working: "edge")),
                       "safari")
    }

    func test_first_answering_fingerprint_wins() {
        XCTAssertEqual(findWorkingFingerprint(reality(), using: FakeMeasurer(working: "safari")),
                       "safari")
    }

    func test_falls_back_to_first_candidate_when_nothing_answers() {
        XCTAssertEqual(findWorkingFingerprint(reality(), using: FakeMeasurer(working: "нет такого")),
                       "firefox")
    }
}
