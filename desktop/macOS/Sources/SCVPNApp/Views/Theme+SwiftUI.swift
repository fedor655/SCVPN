import SCVPNCore
import SwiftUI

/// Шрифты окна macOS. Цвета и фирменный знак живут в `SCVPNCore/UI/`: они
/// одинаковы на macOS и iOS, а размеры и Menlo — про десктопное окно.
extension Font {
    /// Системный шрифт интерфейса: на macOS это SF.
    static func scvpnUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Моноширинный для логов — Menlo, как в Python-версии.
    static func scvpnMono(_ size: CGFloat) -> Font {
        .custom("Menlo", size: size)
    }

    /// Надпись SCVPN в шапке: разрядка задаётся отдельно, через `.tracking(3)`.
    static var wordmark: Font { .system(size: 14, weight: .bold) }
    static var statusBig: Font { .system(size: 20, weight: .bold) }
    static var substatus: Font { .system(size: 12) }
    static var section: Font { .system(size: 10, weight: .bold) }
}
