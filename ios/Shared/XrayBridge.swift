import Foundation
import SCVPNCore
#if canImport(LibXrayKit)
import LibXrayKit
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

    #if canImport(LibXrayKit)
    static var available: Bool { true }

    /// Весь API libXray — одна функция `CGoInvoke(requestJSON) -> responseJSON`.
    /// Метод и его аргументы едут внутри JSON, ответ приходит в конверте
    /// `{"success":…,"data":…,"error":…}`.
    ///
    /// **Номер версии API меняется от сборки к сборке**, и на чужой libXray
    /// отвечает `unsupported apiVersion`. Гадать бессмысленно: версия
    /// определяется один раз при первом вызове перебором, безобидным методом
    /// `xrayVersion`. Дешевле трёх лишних вызовов на запуск — сломанная сборка
    /// после обновления фреймворка.
    private static let versionLock = NSLock()
    nonisolated(unsafe) private static var negotiated: Int?

    private static func apiVersion() -> Int {
        versionLock.lock(); defer { versionLock.unlock() }
        if let negotiated { return negotiated }
        for candidate in [2, 1, 3, 0] where !failsVersionCheck(candidate) {
            negotiated = candidate
            return candidate
        }
        negotiated = 2   // ничего не подошло — пусть ошибка будет говорящей
        return 2
    }

    private static func failsVersionCheck(_ version: Int) -> Bool {
        let request = #"{"apiVersion":\#(version),"method":"xrayVersion"}"#
        return LibXrayCore.invoke(request).contains("unsupported apiVersion")
    }

    @discardableResult
    private static func invoke(_ method: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        var request: [String: Any] = ["apiVersion": apiVersion(), "method": method]
        if !payload.isEmpty {
            request["payload"] = payload
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8) else {
            throw Failure.core("не собрал запрос к ядру")
        }
        let reply = LibXrayCore.invoke(text)
        guard let replyData = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
            throw Failure.core("ядро ответило не JSON")
        }
        guard object["success"] as? Bool == true else {
            throw Failure.core((object["error"] as? String) ?? "без объяснения")
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    /// Запуск ядра конфигом.
    ///
    /// Имя поля тоже разное между сборками: старые ждут `configJSON` у метода
    /// `runXrayFromJson`, новые — `xrayJson` у `runXray`. Пробуем оба, иначе
    /// обновление фреймворка молча ломает подключение.
    static func start(configJSON: String) throws {
        do {
            try invoke("runXray", payload: ["xrayJson": configJSON])
        } catch {
            try invoke("runXrayFromJson", payload: ["configJSON": configJSON])
        }
    }

    static func stop() {
        try? invoke("stopXray")
    }

    static var isRunning: Bool {
        ((try? invoke("getXrayState"))?["running"] as? Bool) ?? false
    }

    static var version: String {
        do {
            return (try invoke("xrayVersion")["version"] as? String) ?? "ответ без версии"
        } catch {
            // Причину видно только здесь: молчаливое «не отвечает» на экране
            // отлаживать нечем.
            return "\(error)"
        }
    }

    /// Задержка в мс или -1.
    ///
    /// `pingBatch` поднимает ядро и гасит его внутри вызова — ровно то, что
    /// нужно для замера: собственный туннель при этом не трогается.
    static func measureDelay(configJSON: String, url: String) -> Int {
        // Замер принимает только путь к файлу, поэтому конфиг кладётся во
        // временную папку и удаляется сразу после.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).json")
        guard (try? configJSON.write(to: file, atomically: true, encoding: .utf8)) != nil
        else { return -1 }
        defer { try? FileManager.default.removeItem(at: file) }

        // Оба поколения полей разом: лишний ключ сборка просто игнорирует.
        let payload: [String: Any] = [
            "configs": [["configPath": file.path, "xrayJson": configJSON,
                         "outboundTag": "proxy"]],
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
