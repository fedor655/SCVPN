import SwiftUI

/// Палитра в виде цветов SwiftUI.
///
/// Значения живут строками в `SCVPNCore.Palette` и оттуда же сверяются с
/// Android — здесь только перевод. Заводить второй список цветов нельзя: он
/// разойдётся с Android молча, как это уже было в Python-версии.
extension Color {
    public static let scvpnBG = Color(hex: Palette.bg)
    public static let scvpnSurface = Color(hex: Palette.surface)
    public static let scvpnSurfaceHi = Color(hex: Palette.surfaceHi)
    public static let scvpnStroke = Color(hex: Palette.stroke)
    public static let scvpnText = Color(hex: Palette.text)
    public static let scvpnDim = Color(hex: Palette.dim)
    public static let scvpnMuted = Color(hex: Palette.muted)
    public static let scvpnAccent = Color(hex: Palette.accent)

    public init(hex: String) {
        guard let c = rgbComponents(hex) else {
            self = .black
            return
        }
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
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
public struct BrandmarkShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
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

public struct BrandmarkView: View {
    public var side: CGFloat
    /// Без цвета — фирменный градиент. Он нужен только чтобы крупная фигура не
    /// выглядела плоской заливкой.
    public var color: Color?
    public var widthScale: CGFloat = 1

    public init(side: CGFloat, color: Color? = nil, widthScale: CGFloat = 1) {
        self.side = side; self.color = color; self.widthScale = widthScale
    }

    public var body: some View {
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
