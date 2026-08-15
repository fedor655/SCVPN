import SCVPNCore
import SwiftUI

/// Шрифты iOS-экрана. Цвета и знак — общие, из `SCVPNCore/UI/`.
///
/// Размеры чуть крупнее десктопных: палец не мышь, и читать телефон приходится
/// на вытянутой руке.
extension Font {
    static func scvpnUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func scvpnMono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    static var wordmark: Font { .system(size: 15, weight: .bold) }
    static var statusBig: Font { .system(size: 22, weight: .bold) }
    static var substatus: Font { .system(size: 13) }
    static var section: Font { .system(size: 11, weight: .bold) }
}
