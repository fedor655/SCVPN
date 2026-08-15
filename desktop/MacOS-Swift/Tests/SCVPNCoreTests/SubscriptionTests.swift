import XCTest
@testable import SCVPNCore

final class SubscriptionTests: StorageIsolatedTestCase {

    private func stub(name: String) -> Server {
        Server(proto: "vless", name: name, address: "0.0.0.0", port: 1)
    }

    func test_recognizes_panel_stub_and_explains_it() {
        // Панель не возвращает ошибку HTTP: она отдаёт один фиктивный сервер,
        // у которого в имени написана причина. Без этой проверки строка молча
        // попадала бы в список — и выглядела как «сервер App not supported».
        XCTAssertThrowsError(try raiseIfPanelStub([stub(name: "App not supported")],
                                                  headers: [:])) { e in
            XCTAssertTrue("\(e)".contains("App not supported"), "\(e)")
        }
    }

    func test_device_limit_gets_its_own_explanation() {
        XCTAssertThrowsError(try raiseIfPanelStub(
            [stub(name: "limit of devices reached")],
            headers: ["x-hwid-max-devices-reached": "true"])) { e in
            XCTAssertTrue("\(e)".contains("лимит устройств"), "\(e)")
        }
    }

    func test_unsupported_hwid_gets_its_own_explanation() {
        XCTAssertThrowsError(try raiseIfPanelStub(
            [stub(name: "")], headers: ["x-hwid-not-supported": "true"])) { e in
            XCTAssertTrue("\(e)".contains("идентификатор устройства"), "\(e)")
        }
    }

    func test_stub_without_a_reason_still_explains_itself() {
        XCTAssertThrowsError(try raiseIfPanelStub([stub(name: "")], headers: [:])) { e in
            XCTAssertTrue("\(e)".contains("без пояснения"), "\(e)")
        }
    }

    func test_empty_list_is_not_a_stub() {
        // Пустая подписка — это пустая подписка, а не сообщение панели.
        XCTAssertNoThrow(try raiseIfPanelStub([], headers: [:]))
    }

    func test_one_dead_server_among_live_ones_is_not_a_stub() {
        // Заглушкой считаем только ответ, состоящий из неё целиком: иначе один
        // мёртвый сервер в списке ронял бы всю подписку.
        let live = Server(proto: "vless", name: "Токио", address: "a.b", port: 443)
        XCTAssertNoThrow(try raiseIfPanelStub([stub(name: "App not supported"), live],
                                              headers: [:]))
    }

    func test_loopback_and_empty_address_count_as_stub() {
        for address in ["127.0.0.1", ""] {
            let s = Server(proto: "vless", name: "нет", address: address, port: 443)
            XCTAssertThrowsError(try raiseIfPanelStub([s], headers: [:]), address)
        }
    }

    func test_header_case_does_not_hide_the_device_limit() {
        // Заголовки регистронезависимы, а по этому ветвится текст объяснения.
        XCTAssertThrowsError(try raiseIfPanelStub(
            [stub(name: "x")], headers: ["X-HWID-Max-Devices-Reached": "TRUE"])) { e in
            XCTAssertTrue("\(e)".contains("лимит устройств"), "\(e)")
        }
    }

    func test_user_agent_is_frozen() {
        // По этому значению панели решают, отдать список vless://-ссылок или
        // clash-конфиг, который мы не разбираем.
        XCTAssertEqual(defaultUserAgent, "v2rayNG/1.9.5")
    }

    func test_bad_url_is_refused_before_the_network() async {
        // Корень данных подменён базовым классом: за проверкой ссылки стоит
        // deviceHeaders() -> deviceID(), который ПИШЕТ settings.json.
        // URL(string:) на macOS 26 не требует ни схемы, ни хоста и глотает
        // «не ссылка» как относительный путь. Без своей проверки пользователь
        // получал бы «домен провайдера заблокирован» вместо «это не ссылка».
        for bad in ["не ссылка", "", "ftp://example.com/sub", "https://", "/просто/путь"] {
            do {
                _ = try await fetchSubscription(url: bad)
                XCTFail("кривая ссылка прошла: \(bad)")
            } catch let e as SubscriptionError {
                XCTAssertTrue(e.message.contains("не похоже на ссылку"), "\(bad): \(e.message)")
            } catch {
                XCTFail("не тот тип ошибки на \(bad): \(error)")
            }
        }
    }
}
