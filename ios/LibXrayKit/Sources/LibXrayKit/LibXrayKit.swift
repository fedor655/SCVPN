import Foundation

/// Тонкая обёртка над единственной функцией ядра: `CGoInvoke(json) -> json`.
///
/// Строку ответа выделяет Go и освобождать её обязан он же — отсюда `CGoFree`.
/// Забыть его значит течь на каждом вызове пинга.
public enum LibXrayCore {
    public static func invoke(_ requestJSON: String) -> String {
        requestJSON.withCString { pointer in
            // CGoInvoke объявлен как char*, а не const char*: Go копирует
            // строку себе сразу, поэтому временный буфер тут безопасен.
            guard let raw = CGoInvoke(UnsafeMutablePointer(mutating: pointer)) else { return "" }
            defer { CGoFree(raw) }
            return String(cString: raw)
        }
    }
}
