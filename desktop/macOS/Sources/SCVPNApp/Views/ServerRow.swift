import SCVPNCore
import SwiftUI

/// Строка списка серверов как карточка.
///
/// Выбранная обводится акцентом, остальные — приглушённым штрихом. Пинг стоит
/// справа от имени и **подписывается словами**, когда сервер не ответил: одной
/// яркости для такого случая мало.
struct ServerRow: View {
    var server: Server
    var ping: PingResult
    var selected: Bool

    @State private var hovering = false

    var body: some View {
        let label = pingLabel(ping)
        HStack(alignment: .top, spacing: Style.rowGap) {
            VStack(alignment: .leading, spacing: Style.rowTextSpacing) {
                Text(server.title)
                    .font(.rowTitle)
                    .foregroundStyle(Color.scvpnText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.rowDetail)
                    .foregroundStyle(Color.scvpnDim)
                    .lineLimit(1)
            }
            Spacer(minLength: Style.rowGap)
            if !label.text.isEmpty {
                Text(label.text)
                    .font(.rowPing)
                    .foregroundStyle(Color(hex: label.color))
            }
        }
        .padding(.horizontal, Style.rowPaddingH)
        .padding(.vertical, Style.rowPaddingV)
        .frame(height: Style.rowHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Style.rowCorner)
                .fill(hovering ? Color.scvpnSurfaceHi : Color.scvpnSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Style.rowCorner)
                .stroke(selected ? Color.scvpnAccent : Color.scvpnStroke,
                        lineWidth: selected ? Style.strokeSelected : Style.stroke)
        )
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
