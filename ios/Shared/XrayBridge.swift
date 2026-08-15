import Foundation
import SCVPNCore

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
        case start(String)
        var description: String {
            switch self {
            case .noCore:
                return """
                    В этой сборке нет ядра Xray.

                    Собери LibXray.xcframework и положи в ios/Frameworks/, \
                    см. ios/README.md.
                    """
            case .start(let why): return "ядро не запустилось: \(why)"
            }
        }
    }

    #if canImport(LibXray)
    // Сигнатуры libXray выписываются в план (Приложение Д) при первой сборке
    // фреймворка; до тех пор ветка не компилируется ни у кого и трогать её
    // наугад нельзя.
    #error("подключи LibXray: заполни вызовы по фактическому заголовку фреймворка")
    #else
    static var available: Bool { false }

    static func start(configJSON: String) throws { throw Failure.noCore }
    static func stop() {}
    static func measureDelay(configJSON: String, url: String) -> Int { -1 }
    #endif

    func measure(configJSON: String, url: String) -> Int {
        Self.measureDelay(configJSON: configJSON, url: url)
    }
}
