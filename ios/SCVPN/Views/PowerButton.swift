import SCVPNCore
import SwiftUI

/// Круглая кнопка подключения.
///
/// Состояние показывается **формой кольца**, а не только цветом: подключено —
/// толстое сплошное, ошибка — пунктир, простой — тонкое приглушённое. Тема
/// чёрно-белая, иначе состояния не различить.
struct PowerButton: View {
    var state: ConnectionState
    var side: CGFloat = 168
    var action: () -> Void

    /// Сколько секунд на оборот бегущей дуги.
    private let turn: Double = 1.4
    @State private var spin = false

    var body: some View {
        let ring = state.ring
        let color = Color(hex: ring.color)
        let inset = ring.width

        Button(action: action) {
            ZStack {
                Circle().fill(Color.scvpnSurface).padding(inset)

                if state == .connecting {
                    Circle()
                        .stroke(color.opacity(0.22), lineWidth: ring.width)
                        .padding(inset)
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(color, style: StrokeStyle(lineWidth: ring.width, lineCap: .round))
                        .padding(inset)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: turn).repeatForever(autoreverses: false),
                                   value: spin)
                        .onAppear { spin = true }
                } else {
                    Circle()
                        .stroke(color, style: StrokeStyle(
                            lineWidth: ring.width,
                            // Пунктир в долях толщины линии — как на десктопе.
                            dash: ring.dashed ? [ring.width * 3, ring.width * 3] : []))
                        .padding(inset)
                }

                BrandmarkView(side: side * 0.48,
                              color: state == .connected ? nil : color)
            }
            .frame(width: side, height: side)
            // Нажимается ровно круг: без inset область выходила бы за кольцо.
            .contentShape(Circle().inset(by: inset))
        }
        .buttonStyle(.plain)
    }
}
