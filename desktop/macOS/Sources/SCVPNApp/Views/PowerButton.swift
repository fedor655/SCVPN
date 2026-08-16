import SCVPNCore
import SwiftUI

/// Круглая кнопка подключения.
///
/// Состояние показывается **формой кольца**, а не только цветом: подключено —
/// толстое сплошное, ошибка — пунктир, простой — тонкое приглушённое. В
/// чёрно-белой теме иначе никак, и это осознанное решение доступности.
///
/// Кнопка — единственная вещь в окне, у которой есть объём: заливка идёт
/// радиальным переходом, будто свет падает сверху, и внутри кольца проходит
/// кромка шайбы. Всё остальное на экране плоское, поэтому взгляд идёт сюда
/// первым.
struct PowerButton: View {
    var state: ConnectionState
    var side: CGFloat = Style.powerSide
    var action: () -> Void

    @State private var hovering = false
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
                // уходит в фон. При наведении вся заливка светлеет на ступень.
                Circle()
                    .fill(RadialGradient(
                        colors: hovering
                            ? [Color.scvpnStroke, Color.scvpnSurface]
                            : [Color.scvpnSurfaceHi, Color.scvpnSurface],
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
                            // как setDashPattern([3, 3]) в Qt-версии.
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
        }
        .buttonStyle(.plain)
        // Нажимается ровно круг, а не квадрат вокруг него.
        .contentShape(Circle().inset(by: inset))
        // Наведение считается вручную, по расстоянию до центра.
        //
        // `onHover` для этого не годится, и `contentShape` его не
        // ограничивает: область слежения у него — прямоугольная рамка вида,
        // то есть квадрат, описанный вокруг кнопки. Курсор в углу этого
        // квадрата — за 100 pt от кольца — зажигал заливку. Проверено
        // замером пикселя: с `onHover` угол давал ту же яркость, что и центр.
        .onContinuousHover { phase in
            guard case .active(let point) = phase else {
                hovering = false
                return
            }
            let radius = side / 2 - inset
            let dx = point.x - side / 2
            let dy = point.y - side / 2
            hovering = dx * dx + dy * dy <= radius * radius
        }
        // Именно `.animation(_:value:)`, а не `withAnimation` в модели:
        // состояние приходит из ядра, и оборачивать каждое его присваивание
        // значило бы размазать вид по логике подключения.
        .animation(Style.stateChange, value: state)
    }

    /// Кольцо, которое медленно дышит, пока ничего не происходит.
    ///
    /// Нужно затем, что в простое окно выглядело замёрзшим: ни одного
    /// движущегося пикселя, и непонятно, живо ли приложение вообще. Дыхание
    /// меняет только яркость и только в простое — форма кольца, по которой
    /// состояния и различаются, остаётся прежней.
    ///
    /// Расписание задано частотой, а не `.animation`: окно висит открытым
    /// часами, и гонять полный refresh rate ради медленного затухания
    /// незачем.
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
