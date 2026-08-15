import SCVPNCore
import SwiftUI

/// Шапка окна.
///
/// На macOS она **и есть** полоса заголовка: системной больше нет, содержимое
/// заведено под неё. Слева оставлено место кнопкам окна, поэтому значок рядом с
/// ними не ставим — тесно, остаётся одна надпись.
struct HeaderView<Menu: View>: View {
    var onPing: () -> Void
    var onAdd: () -> Void
    var onRefresh: () -> Void
    @ViewBuilder var menu: () -> Menu

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
            HeaderButton(systemName: "arrow.clockwise", help: "Обновить подписки",
                         action: onRefresh)
            HeaderMenuButton(menu: menu)
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

/// Кнопка «⋯», раскрывающая меню. Отдельно от `HeaderButton`, потому что
/// `Menu` не кнопка и стилизуется иначе.
struct HeaderMenuButton<Menu: View>: View {
    @ViewBuilder var menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        SwiftUI.Menu {
            menu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15))
                .foregroundStyle(hovering ? Color.scvpnText : Color.scvpnDim)
                .frame(width: HeaderMetrics.buttonSide, height: HeaderMetrics.buttonSide)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Color.scvpnSurfaceHi : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: HeaderMetrics.buttonSide)
        .onHover { hovering = $0 }
        .help("Настройки и подписки")
    }
}
