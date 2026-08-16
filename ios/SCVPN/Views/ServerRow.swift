import SCVPNCore
import SwiftUI

/// Строка списка серверов как карточка.
///
/// Выбранная обводится акцентом. Пинг справа и **подписывается словами**, когда
/// сервер не ответил: одной яркости для такого случая мало.
struct ServerRow: View {
    var server: Server
    var ping: PingResult
    var selected: Bool

    var body: some View {
        let label = pingLabel(ping)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.title)
                    .font(.scvpnUI(15))
                    .foregroundStyle(Color.scvpnText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.scvpnUI(12))
                    .foregroundStyle(Color.scvpnDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !label.text.isEmpty {
                Text(label.text)
                    .font(.scvpnUI(12))
                    .foregroundStyle(Color(hex: label.color))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.scvpnSurface))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.scvpnAccent : Color.scvpnStroke,
                        lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [server.proto.uppercased(), "\(server.address):\(server.port)"]
        if server.security == "reality" || server.security == "tls" {
            parts.append(server.security.uppercased())
        }
        return parts.joined(separator: " · ")
    }
}
