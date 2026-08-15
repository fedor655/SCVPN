import SCVPNCore
import SwiftUI

/// Шапка окна.
///
/// На macOS она **и есть** полоса заголовка: системной больше нет, содержимое
/// заведено под неё. Слева оставлено место кнопкам окна, поэтому значок рядом с
/// ними не ставим — тесно, остаётся одна надпись.
struct HeaderView: View {
    var onPing: () -> Void
    var onAdd: () -> Void
    var onMenu: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text("SCVPN")
                .font(.wordmark)
                .tracking(3)
                .foregroundStyle(Color.scvpnText)
            Spacer(minLength: 0)
            HeaderButton(systemName: "waveform.path", help: "Измерить пинг серверов",
                         action: onPing)
            HeaderButton(systemName: "plus", help: "Добавить сервер или подписку",
                         action: onAdd)
            HeaderButton(systemName: "ellipsis", help: "Ещё", action: onMenu)
        }
        .padding(EdgeInsets(top: HeaderMetrics.top, leading: HeaderMetrics.left,
                            bottom: 10, trailing: 12))
        .frame(height: HeaderMetrics.height)
    }
}

/// Плоская кнопка шапки: без фона и рамки, подсветка только при наведении.
struct HeaderButton: View {
    var systemName: String
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                .foregroundStyle(hovering ? Color.scvpnText : Color.scvpnDim)
                .frame(width: HeaderMetrics.buttonSide, height: HeaderMetrics.buttonSide)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Color.scvpnSurfaceHi : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
