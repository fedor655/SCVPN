import SCVPNCore
import SwiftUI

/// Круглая кнопка подключения.
///
/// Состояние показывается **формой кольца**, а не только цветом: подключено —
/// толстое сплошное, ошибка — пунктир, простой — тонкое приглушённое. В
/// чёрно-белой теме иначе никак, и это осознанное решение доступности.
struct PowerButton: View {
    var state: ConnectionState
    var side: CGFloat = Style.powerSide
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        let ring = state.ring
        let color = Color(hex: ring.color)
        let inset = ring.width

        Button(action: action) {
            ZStack {
                // Заливка чуть светлее при наведении — единственная реакция
                // на мышь.
                Circle()
                    .fill(hovering ? Color.scvpnSurfaceHi : Color.scvpnSurface)
                    .padding(inset)

                if state == .connecting {
                    // Тусклое кольцо целиком плюс яркая дуга, бегущая по нему.
                    Circle()
                        .stroke(color.opacity(Style.powerTrackOpacity), lineWidth: ring.width)
                        .padding(inset)
                    spinningArc(color: color, width: ring.width, inset: inset)
                } else {
                    Circle()
                        .stroke(color, style: StrokeStyle(
                            lineWidth: ring.width,
                            // Пунктир задаётся в долях толщины линии — так же,
                            // как setDashPattern([3, 3]) в Qt-версии.
                            dash: ring.dashed ? [ring.width * 3, ring.width * 3] : []))
                        .padding(inset)
                }

                // При «подключено» знак рисуется фирменным градиентом, в
                // остальных состояниях — цветом состояния.
                BrandmarkView(side: side * 0.48,
                              color: state == .connected ? nil : color)
            }
            .frame(width: side, height: side)
            // Кликается ровно круг, а не квадрат вокруг него: без inset
            // чувствительная область выходила за кольцо на его толщину, и
            // кнопка срабатывала мимо видимой границы.
            .contentShape(Circle().inset(by: inset))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Бегущая дуга.
    ///
    /// Через `TimelineView`, а не `withAnimation(.repeatForever)`. Второй здесь
    /// не работает: сброс угла и запуск анимации попадают в один такт, SwiftUI
    /// их склеивает, и дуга просто стоит — ровно то, что было видно на экране.
    /// `TimelineView` считает угол от времени и не зависит от того, когда
    /// пересобрался вид. По сути это тот же таймер на 16 мс, которым крутил
    /// Qt-вариант, только без ручного управления им.
    private func spinningArc(color: Color, width: Double, inset: Double) -> some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Style.powerSpin) / Style.powerSpin
            Circle()
                .trim(from: 0, to: Style.powerArc)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .padding(inset)
                .rotationEffect(.degrees(t * 360))
        }
    }
}
