import SCVPNCore
import SwiftUI

/// Круглая кнопка подключения.
///
/// Состояние показывается **формой кольца**, а не только цветом: подключено —
/// толстое сплошное, ошибка — пунктир, простой — тонкое приглушённое. Тема
/// чёрно-белая, иначе состояния не различить. Форму задаёт ядро
/// (`ConnectionState.ring`) — она одна на все платформы.
///
/// Кнопка — единственная вещь на экране, у которой есть объём: заливка идёт
/// радиальным переходом, будто свет падает сверху, и внутри кольца проходит
/// кромка шайбы. Всё остальное плоское, поэтому взгляд идёт сюда первым.
///
/// Один в один с macOS (`SCVPNApp/Views/PowerButton.swift`), кроме подсветки
/// под курсором: курсора на телефоне нет, и заливка всегда одна.
struct PowerButton: View {
    var state: ConnectionState
    var side: CGFloat = Style.powerSide
    var action: () -> Void

    /// Точка отсчёта «дыхания». Фиксируется на создании вида: иначе расписание
    /// пересоздавалось бы на каждой перерисовке и фаза прыгала.
    @State private var since = Date()

    var body: some View {
        let ring = state.ring
        let color = Color(hex: ring.color)
        let inset = ring.width

        Button(action: action) {
            ZStack {
                // Свет сверху: центр перехода смещён вверх, к краям шайба
                // уходит в фон.
                Circle()
                    .fill(RadialGradient(
                        colors: [Color.scvpnSurfaceHi, Color.scvpnSurface],
                        center: UnitPoint(x: 0.5, y: 0.34),
                        startRadius: 0,
                        endRadius: side * 0.62))
                    .padding(inset)

                // Кромка шайбы. Тонкая и заметно меньше кольца состояния —
                // спутать их нельзя, а плоский круг она превращает в предмет.
                Circle()
                    .stroke(Color.scvpnStroke, lineWidth: Style.hairline)
                    .padding(inset + side * Style.powerEdgeInset)

                // Кольца разных состояний — разные виды, поэтому смена идёт
                // растворением одного в другое. Толщину и пунктир между собой
                // не «доанимировать»: пунктир не интерполируется вовсе, а
                // рывок с 3 на 5 читался бы как подёргивание.
                if state == .connecting {
                    // Тусклое кольцо целиком плюс яркая дуга, бегущая по нему.
                    Circle()
                        .stroke(color.opacity(Style.powerTrackOpacity), lineWidth: ring.width)
                        .padding(inset)
                    spinningArc(color: color, width: ring.width, inset: inset)
                } else if state == .idle {
                    breathingRing(color: color, width: ring.width, inset: inset)
                } else {
                    Circle()
                        .stroke(color, style: StrokeStyle(
                            lineWidth: ring.width,
                            // Пунктир задаётся в долях толщины линии — так же,
                            // как на десктопе.
                            dash: ring.dashed ? [ring.width * 3, ring.width * 3] : []))
                        .padding(inset)
                }

                // При «подключено» знак рисуется фирменным градиентом, в
                // остальных состояниях — цветом состояния. `id` заставляет
                // SwiftUI считать это сменой вида, а не правкой прежнего:
                // градиент и сплошная заливка друг в друга не переходят, зато
                // растворяются.
                BrandmarkView(side: side * 0.48,
                              color: state == .connected ? nil : color)
                    .id(state == .connected)
            }
            .frame(width: side, height: side)
            // Нажимается ровно круг: без inset область выходила бы за кольцо.
            .contentShape(Circle().inset(by: inset))
        }
        .buttonStyle(.plain)
        // Именно `.animation(_:value:)`, а не `withAnimation` в модели:
        // состояние приходит от расширения, и оборачивать каждое его
        // присваивание значило бы размазать вид по логике подключения.
        .animation(Style.stateChange, value: state)
    }

    /// Кольцо, которое медленно дышит, пока ничего не происходит.
    ///
    /// Нужно затем, что в простое экран выглядел замёрзшим: ни одного
    /// движущегося пикселя, и непонятно, живо ли приложение вообще. Дыхание
    /// меняет только яркость и только в простое — форма кольца, по которой
    /// состояния и различаются, остаётся прежней.
    ///
    /// Расписание задано частотой, а не `.animation`: ради медленного затухания
    /// гонять полный refresh rate незачем, а на телефоне это ещё и батарея.
    private func breathingRing(color: Color, width: Double, inset: Double) -> some View {
        TimelineView(.periodic(from: since, by: 1 / Style.powerBreathFPS)) { timeline in
            let t = timeline.date.timeIntervalSince(since)
                .truncatingRemainder(dividingBy: Style.powerBreath) / Style.powerBreath
            // Синус даёт плавный разворот на обоих концах: без него вдох и
            // выдох стыкуются рывком.
            let wave = (1 - cos(2 * .pi * t)) / 2
            let low = Style.powerBreathLow
            Circle()
                .stroke(color.opacity(low + (1 - low) * wave), lineWidth: width)
                .padding(inset)
        }
    }

    /// Бегущая дуга.
    ///
    /// Через `TimelineView`, а не `withAnimation(.repeatForever)`. Второй здесь
    /// ненадёжен: сброс угла и запуск анимации попадают в один такт, SwiftUI их
    /// склеивает, и дуга просто стоит. `TimelineView` считает угол от времени и
    /// не зависит от того, когда пересобрался вид.
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
