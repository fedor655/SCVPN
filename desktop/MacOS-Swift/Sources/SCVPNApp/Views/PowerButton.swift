import SCVPNCore
import SwiftUI

/// Круглая кнопка подключения.
///
/// Состояние показывается **формой кольца**, а не только цветом: подключено —
/// толстое сплошное, ошибка — пунктир, простой — тонкое приглушённое. В
/// чёрно-белой теме иначе никак, и это осознанное решение доступности.
struct PowerButton: View {
    var state: ConnectionState
    var side: CGFloat = 132
    var action: () -> Void

    @State private var hovering = false
    @State private var spin: Double = 0

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
                        .stroke(color.opacity(0.22), lineWidth: ring.width)
                        .padding(inset)
                    Circle()
                        .trim(from: 0, to: 100.0 / 360.0)
                        .stroke(color, style: StrokeStyle(lineWidth: ring.width, lineCap: .round))
                        .padding(inset)
                        .rotationEffect(.degrees(spin))
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
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { restartSpin() }
        .onChange(of: state) { _ in restartSpin() }
    }

    private func restartSpin() {
        spin = 0
        guard state == .connecting else { return }
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            spin = 360
        }
    }
}
