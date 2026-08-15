import Foundation

/// Устойчивый base64: паддинга может не быть, алфавит может быть url-safe.
///
/// `Data(base64Encoded:)` в чистом виде тут не годится — он требует и
/// правильной длины, и стандартного алфавита, а панели шлют и то, и другое как
/// придётся. Терять из-за этого всю подписку нельзя.
public func b64decode(_ s: String) throws -> Data {
    var data = s.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let pad = (4 - data.count % 4) % 4
    data += String(repeating: "=", count: pad)
    guard let decoded = Data(base64Encoded: data) else {
        throw ValidationError("не base64")
    }
    return decoded
}

/// То же, но текстом. Битые байты заменяются, а не роняют разбор: одна кривая
/// строка не должна стоить пользователю всей подписки.
public func b64decodeText(_ s: String) throws -> String {
    String(decoding: try b64decode(s), as: UTF8.self)
}
