import SCVPNCore
import SwiftUI

/// Строка списка серверов.
///
/// Карточки с рамкой не осталось: строки плоские и разделены волосяной линией.
/// Так список весит меньше кнопки питания — единственного объёмного элемента
/// экрана, — а раньше десяток одинаково обведённых карточек забирал внимание на
/// себя.
///
/// **Выбор показывается маркером слева и яркостью имени**, а не обводкой:
/// прежняя разница между рамкой в 1 и 1.5 пикселя того же белого на чёрном фоне
/// почти не читалась, тем более на телефоне в руке.
///
/// Пинг стоит справа и **подписывается словами**, когда сервер не ответил:
/// одной яркости для такого случая мало.
struct ServerRow: View {
    var server: Server
    var ping: PingResult
    var selected: Bool
    /// Последней строке линия снизу не нужна — под ней и так край списка.
    var last: Bool
    /// Нажатие выбирает сервер. Раньше висело жестом снаружи; кнопка нужна
    /// затем, что только она знает про нажатие и умеет подсветить полосу под
    /// пальцем. Поведение то же: одно касание — выбор, долгое — контекстное
    /// меню списка.
    var action: () -> Void

    var body: some View {
        let label = pingLabel(ping)
        Button(action: action) {
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
                    // Адрес яркость не теряет: приглуши его вслед за именем, и
                    // он уйдёт под порог читаемости.
                    Text(subtitle)
                        .font(.rowDetail)
                        .foregroundStyle(Color.scvpnDim)
                        .lineLimit(1)
                }
                .padding(.leading, Style.rowTextLeading)

                Spacer(minLength: Style.rowGap)

                // Пинг стоит колонкой постоянной ширины: значения выравниваются
                // по правому краю и читаются столбиком, а не пляшут за именем.
                // До замера — прочерк, а не пустота: пустое место справа
                // выглядело так, будто строку не дорисовали.
                Text(label.text.isEmpty ? "—" : label.text)
                    .font(.rowPing)
                    .foregroundStyle(label.text.isEmpty
                                     ? Color.scvpnMuted
                                     : Color(hex: label.color))
                    .lineLimit(1)
                    .frame(width: Style.pingColumn, alignment: .trailing)
            }
            .padding(.horizontal, Style.listPadding)
        }
        .buttonStyle(RowButtonStyle(last: last))
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

/// Оформление строки-кнопки: высота, подсветка под пальцем и разделитель.
///
/// Всё это живёт в стиле, а не в самой строке, потому что подсветка обязана
/// идти **от края до края экрана** — нажимается вся полоса, и это должно быть
/// видно. Внутри строки такой фон пришлось бы рисовать в обход её же полей.
private struct RowButtonStyle: ButtonStyle {
    var last: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: Style.rowHeight)
            .background(configuration.isPressed ? Color.scvpnSurface : Color.clear)
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle()
                        .fill(Color.scvpnStroke)
                        .frame(height: Style.stroke)
                        .padding(.leading, Style.listPadding)
                }
            }
            // Без явной формы нажимаются только сами надписи, а не полоса
            // целиком: между именем и пингом попасть было бы некуда.
            .contentShape(Rectangle())
    }
}
