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
            VStack(alignment: .leading, spacing: 14) {
                Text("Вставь ссылку сервера (vless://, vmess://, trojan://, ss://) "
                     + "или адрес подписки.")
                    .font(.scvpnUI(13))
                    .foregroundStyle(Color.scvpnDim)

                TextField("ссылка", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3...6)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.scvpnSurface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.scvpnStroke))
                    .foregroundStyle(Color.scvpnText)

                HStack(spacing: 12) {
                    Button("Вставить") {
                        text = UIPasteboard.general.string ?? text
                    }
                    Button("Сканировать QR") { scanning = true }
                }
                .font(.scvpnUI(14))

                Spacer()
            }
            .padding(16)
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
