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
        HStack(spacing: Style.headerSpacing) {
            Text("SCVPN")
                .font(.wordmark)
                .tracking(Style.wordmarkTracking)
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
                            bottom: Style.headerBottom, trailing: Style.headerTrailing))
        .frame(height: HeaderMetrics.height)
    }
}

/// Плоская кнопка шапки: ни фона, ни рамки — при наведении светлеет сам знак.
///
/// Подложка под курсором была раньше и ушла намеренно. В окне ровно один
/// объёмный элемент — кнопка питания; всё остальное плоское, иначе четыре
/// прямоугольника в шапке спорят с ней за внимание. Область нажатия при этом
/// осталась прежней, 28×28: она задаётся `frame`, а не фоном.
struct HeaderButton: View {
    var systemName: String
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Style.headerIcon))
                .foregroundStyle(hovering ? Color.scvpnText : Color.scvpnDim)
                .frame(width: HeaderMetrics.buttonSide, height: HeaderMetrics.buttonSide)
                // Без явной формы нажимается только сам глиф, а не квадрат
                // вокруг него — попасть в тонкую стрелку мышью тяжело.
                .contentShape(Rectangle())
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
                .font(.system(size: Style.headerIcon))
                .foregroundStyle(hovering ? Color.scvpnText : Color.scvpnDim)
                .frame(width: HeaderMetrics.buttonSide, height: HeaderMetrics.buttonSide)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: HeaderMetrics.buttonSide)
        .onHover { hovering = $0 }
        .help("Настройки и подписки")
    }
}
