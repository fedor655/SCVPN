import Foundation
import SCVPNCore
#if canImport(LibXray)
import LibXray
#endif

/// Фасад над ядром Xray. Единственное место в проекте, где встречается имя
/// `LibXray`, — смена gomobile на FFI меняет этот файл и больше ничего.
///
/// `LibXray.xcframework` в репозитории нет (сторонние бинарники не коммитятся,
/// см. `ios/README.md`), поэтому файл компилируется в двух видах: с ядром и
/// без. Без ядра приложение остаётся полезным — список серверов, подписки,
/// пинг по TCP, — но туннель честно отказывается подниматься, а не делает вид.
struct XrayBridge: DelayMeasuring {

    enum Failure: Error, CustomStringConvertible {
        case noCore
        case core(String)
        var description: String {
            switch self {
            case .noCore:
                return """
                    В этой сборке нет ядра Xray.

                    Собери LibXray.xcframework и положи в ios/Frameworks/, \
                    см. ios/README.md.
                    """
            case .core(let why): return "ядро не запустилось: \(why)"
            }
        }
    }

    #if canImport(LibXray)
    static var available: Bool { true }

    /// Весь API libXray — одна функция `LibXrayInvoke(requestJSON) -> responseJSON`
    /// (`invoke.go`, API-версия 2). Метод и его аргументы едут внутри JSON,
    /// ответ приходит в конверте `{"success":…,"data":…,"error":…}`.
    private static let apiVersion = 2

    @discardableResult
    private static func invoke(_ method: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        var request: [String: Any] = ["apiVersion": apiVersion, "method": method]
        if !payload.isEmpty {
            // payload у libXray — сырой JSON внутри JSON, но gomobile принимает
            // объект: он разбирает его как json.RawMessage при декодировании.
            request["payload"] = payload
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8) else {
            throw Failure.core("не собрал запрос к ядру")
        }
        let reply = LibXrayInvoke(text)
        guard let replyData = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
            throw Failure.core("ядро ответило не JSON")
        }
        guard object["success"] as? Bool == true else {
            throw Failure.core((object["error"] as? String) ?? "без объяснения")
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    static func start(configJSON: String) throws {
        try invoke("runXray", payload: ["xrayJson": configJSON])
    }

    static func stop() {
        try? invoke("stopXray")
    }

    static var isRunning: Bool {
        ((try? invoke("getXrayState"))?["running"] as? Bool) ?? false
    }

    static var version: String {
        ((try? invoke("xrayVersion"))?["version"] as? String) ?? ""
    }

    /// Задержка в мс или -1.
    ///
    /// `pingBatch` поднимает ядро и гасит его внутри вызова — ровно то, что
    /// нужно для замера: собственный туннель при этом не трогается.
    static func measureDelay(configJSON: String, url: String) -> Int {
        let payload: [String: Any] = [
            "configs": [["xrayJson": configJSON, "outboundTag": "proxy"]],
            "timeout": 5,
            "url": url,
        ]
        guard let data = try? invoke("pingBatch", payload: payload),
              let results = data["results"] as? [[String: Any]],
              let first = results.first, first["success"] as? Bool == true,
              let delay = first["delay"] as? NSNumber else { return -1 }
        return delay.intValue
    }
    #else
    static var available: Bool { false }

    static func start(configJSON: String) throws { throw Failure.noCore }
    static func stop() {}
    static var isRunning: Bool { false }
    static var version: String { "" }
    static func measureDelay(configJSON: String, url: String) -> Int { -1 }
    #endif

    func measure(configJSON: String, url: String) -> Int {
        Self.measureDelay(configJSON: configJSON, url: url)
    }
}
