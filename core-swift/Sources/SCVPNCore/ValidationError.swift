import Foundation

/// Пришло то, что исполнять нельзя.
///
/// Живёт отдельным файлом, а не рядом с валидацией конфига sing-box: тип нужен
/// разбору base64 и ссылок, то есть общему коду, а вся остальная валидация —
/// только macOS-демону.
public struct ValidationError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}
