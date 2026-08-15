import SCVPNCore
import SwiftUI

/// Палитра в виде цветов SwiftUI.
///
/// Значения живут строками в `SCVPNCore.Palette` и оттуда же сверяются с
/// Android — здесь только перевод. Заводить второй список цветов нельзя: он
/// разойдётся с Android молча, как это уже было в Python-версии.
extension Color {
    static let scvpnBG = Color(hex: Palette.bg)
    static let scvpnSurface = Color(hex: Palette.surface)
    static let scvpnSurfaceHi = Color(hex: Palette.surfaceHi)
    static let scvpnStroke = Color(hex: Palette.stroke)
    static let scvpnText = Color(hex: Palette.text)
    static let scvpnDim = Color(hex: Palette.dim)
    static let scvpnMuted = Color(hex: Palette.muted)
    static let scvpnAccent = Color(hex: Palette.accent)

    init(hex: String) {
        guard let c = rgbComponents(hex) else {
            self = .black
            return
        }
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}

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

/// Фирменный знак «S».
///
/// Геометрия один в один из `brandmark.py`: две касающиеся окружности, осевая
/// обводится штрихом с круглыми концами, каждая чаша раскрыта на 255°.
///
/// Про углы. В PIL точка дуги — `center + r·(cos a, sin a)` при оси Y **вниз**.
/// Qt считает углы против часовой (`center + r·(cos θ, −sin θ)`), поэтому в
/// `brandmark.py` дуги записаны уже перевёрнутыми: θ = −a. У SwiftUI ось Y
/// вниз, как у PIL, значит углы Qt надо перевернуть обратно — иначе знак
/// выходит зеркальным (проверено живьём: получалась «2» вместо «S»).
///
/// `addRelativeArc` вместо `addArc` намеренно: у второго флаг `clockwise` в
/// перевёрнутом пространстве означает не то, что читается, и ошибиться в нём
/// легче, чем заметить. `delta` двусмысленности не оставляет.
struct BrandmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let r = side * Brandmark.radius
        let cx = rect.minX + (rect.width - side) / 2 + side / 2
        let cy = rect.minY + (rect.height - side) / 2 + side / 2
        let sweep = Double(Brandmark.sweep)

        var path = Path()
        // Верхняя чаша: от свободного конца по дуге до точки касания.
        path.addRelativeArc(center: CGPoint(x: cx, y: cy - r), radius: r,
                            startAngle: .degrees(-15), delta: .degrees(-sweep))
        // Нижняя — от той же точки касания в обратную сторону.
        path.addRelativeArc(center: CGPoint(x: cx, y: cy + r), radius: r,
                            startAngle: .degrees(-90), delta: .degrees(sweep))
        return path
    }
}

struct BrandmarkView: View {
    var side: CGFloat
    /// Без цвета — фирменный градиент. Он нужен только чтобы крупная фигура не
    /// выглядела плоской заливкой.
    var color: Color?
    var widthScale: CGFloat = 1

    var body: some View {
        let style = StrokeStyle(lineWidth: side * Brandmark.strokeWidth * widthScale,
                                lineCap: .round, lineJoin: .round)
        Group {
            if let color {
                BrandmarkShape().stroke(color, style: style)
            } else {
                BrandmarkShape().stroke(
                    LinearGradient(colors: [Color(hex: Brandmark.gradientTop),
                                            Color(hex: Brandmark.gradientBottom)],
                                   startPoint: .init(x: 0.5, y: 0.2),
                                   endPoint: .init(x: 0.5, y: 0.8)),
                    style: style)
            }
        }
        .frame(width: side, height: side)
    }
}
