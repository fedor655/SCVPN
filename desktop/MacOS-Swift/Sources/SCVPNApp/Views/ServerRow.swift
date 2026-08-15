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
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.title)
                    .font(.scvpnUI(13))
                    .foregroundStyle(Color.scvpnText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.scvpnUI(11))
                    .foregroundStyle(Color.scvpnDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !label.text.isEmpty {
                Text(label.text)
                    .font(.scvpnUI(11))
                    .foregroundStyle(Color(hex: label.color))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 58, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.scvpnSurfaceHi : Color.scvpnSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.scvpnAccent : Color.scvpnStroke,
                        lineWidth: selected ? 1.5 : 1)
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
