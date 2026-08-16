import SCVPNCore
import SwiftUI

/// Строка списка серверов.
///
/// Карточки с рамками не осталось: строки плоские и разделены волосяной
/// линией. Так список весит меньше кнопки питания — единственного объёмного
/// элемента окна, — а раньше десяток одинаково обведённых карточек забирал
/// внимание на себя.
///
/// **Выбор показывается маркером слева и яркостью имени**, а не обводкой:
/// прежняя разница между рамкой в 1 и 1.5 пикселя того же белого на чёрном
/// фоне почти не читалась.
///
/// Пинг стоит справа и **подписывается словами**, когда сервер не ответил:
/// одной яркости для такого случая мало.
struct ServerRow: View {
    var server: Server
    var ping: PingResult
    var selected: Bool
    /// Последней строке линия снизу не нужна — под ней и так край списка.
    var last: Bool

    @State private var hovering = false

    var body: some View {
        let label = pingLabel(ping)
        HStack(spacing: 0) {
            Capsule()
                .fill(selected ? Color.scvpnAccent : Color.clear)
                .frame(width: Style.rowMarker)
                .padding(.vertical, Style.rowMarkerInset)

            VStack(alignment: .leading, spacing: Style.rowTextSpacing) {
                Text(server.title)
                    .font(.rowTitle)
                    .foregroundStyle(selected ? Color.scvpnText : Color.scvpnDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.rowDetail)
                    .foregroundStyle(Color.scvpnDim)
                    .lineLimit(1)
            }
            .padding(.leading, Style.rowTextLeading)

            Spacer(minLength: Style.rowGap)

            // Пинг стоит колонкой постоянной ширины: значения выравниваются по
            // правому краю и читаются столбиком, а не пляшут за именем.
            // До замера — прочерк, а не пустота: пустое место справа выглядело
            // так, будто строку не дорисовали.
            Text(label.text.isEmpty ? "—" : label.text)
                .font(.rowPing)
                .foregroundStyle(label.text.isEmpty
                                 ? Color.scvpnMuted
                                 : Color(hex: label.color))
                .lineLimit(1)
                .frame(width: Style.pingColumn, alignment: .trailing)
        }
        .padding(.horizontal, Style.listPadding)
        .frame(height: Style.rowHeight)
        // Подсветка идёт от края до края окна: нажимается вся полоса, и это
        // должно быть видно.
        .background(hovering ? Color.scvpnSurface : Color.clear)
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle()
                    .fill(Color.scvpnStroke)
                    .frame(height: Style.stroke)
                    .padding(.leading, Style.listPadding)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Что видно под именем: протокол, адрес и транспорт — то, по чему
    /// пользователь отличает два сервера с одинаковым названием.
    private var subtitle: String {
        var parts = [server.proto, "\(server.address):\(server.port)"]
        if server.security != "none" { parts.append(server.security) }
        if server.network != "tcp" { parts.append(server.network) }
        return parts.joined(separator: " · ")
    }
}
