import SCVPNCore
import SwiftUI

/// Добавление сервера или подписки одним полем.
///
/// Спрашивать «это ссылка или подписка?» значит перекладывать на человека то,
/// что программа выясняет сама: `vless://…` разбирает парсер ссылок, `http(s)`
/// уходит в подписку.
struct AddSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Style.sheetGap) {
                Text("Вставь ссылку сервера (vless://, vmess://, trojan://, ss://) "
                     + "или адрес подписки.")
                    .font(.scvpnUI(12))
                    .foregroundStyle(Color.scvpnDim)

                // Ссылка — моноширинным: в ней важен каждый знак, и в
                // пропорциональном шрифте не отличить l от 1, когда её вычитывают
                // глазами.
                TextField("ссылка", text: $text, axis: .vertical)
                    .font(.scvpnMono(11))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3...6)
                    .padding(Style.logPadding)
                    .background(RoundedRectangle(cornerRadius: Style.boxCorner)
                        .fill(Color.scvpnSurface))
                    .overlay(RoundedRectangle(cornerRadius: Style.boxCorner)
                        .stroke(Color.scvpnStroke, lineWidth: Style.stroke))
                    .foregroundStyle(Color.scvpnText)

                // Тринадцать, а не двенадцать: это то, во что целятся пальцем, и
                // 13 — самый мелкий кегль шкалы, в который ещё можно попасть.
                HStack(spacing: 12) {
                    Button("Вставить") {
                        text = UIPasteboard.general.string ?? text
                    }
                    Button("Сканировать QR") { scanning = true }
                }
                .font(.scvpnUI(13))

                Spacer()
            }
            .padding(Style.sheetPadding)
            .background(Color.scvpnBG)
            .navigationTitle("Новый сервер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        // Закрываемся только если строку поняли: иначе отказ
                        // остаётся невидимым, а поле — потерянным.
                        if model.addFromLink(text) { dismiss() }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(item: $model.alert) { box in
                Alert(title: Text(box.title), message: Text(box.text),
                      dismissButton: .default(Text("Понятно")))
            }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    text = code
                    scanning = false
                }
            }
        }
    }
}
