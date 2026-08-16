import SCVPNCore
import SwiftUI

/// Добавление сервера или подписки.
///
/// **Одно поле на оба случая.** Тип определяется по самой строке, а не выбором
/// пользователя: ссылку сервера узнаёт парсер, всё остальное с `http(s)`
/// считается подпиской. Спрашивать «это ссылка или подписка?» значило бы
/// перекладывать на человека то, что программа выясняет сама.
struct AddSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Style.sheetGap) {
            Text("""
                Вставь ссылку сервера (vless:// / vmess:// / trojan:// / ss://)
                или URL подписки — либо отсканируй QR-код.
                """)
                .font(.scvpnUI(12))
                .foregroundStyle(Color.scvpnDim)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.scvpnMono(11))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 78)
                .background(RoundedRectangle(cornerRadius: Style.boxCorner).fill(Color.scvpnBG))
                .overlay(RoundedRectangle(cornerRadius: Style.boxCorner)
                .stroke(Color.scvpnStroke, lineWidth: Style.stroke))

            if let problem {
                Text(problem)
                    .font(.scvpnUI(11))
                    .foregroundStyle(Color.scvpnText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Сканировать QR…") { scanning = true }
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Добавить") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
        .padding(Style.sheetPadding)
        .frame(width: Style.sheetWidth)
        .background(Color.scvpnSurface)
        .sheet(isPresented: $scanning) {
            QRScanSheet { code in
                scanning = false
                // Сразу не закрываем: пусть видно, что именно распозналось —
                // QR может оказаться не тем, что человек ожидал.
                text = code
            }
        }
    }

    private func add() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        problem = nil

        if let server = parseLink(value) {
            model.addServer(server)
            dismiss()
            return
        }
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else {
            problem = "Не похоже ни на ссылку сервера, ни на URL подписки."
            return
        }
        busy = true
        Task {
            do {
                try await model.addSubscription(url: value)
                dismiss()
            } catch {
                problem = "\(error)"
            }
            busy = false
        }
    }
}

/// Окно сканера: картинка с камеры и кнопка отмены.
struct QRScanSheet: View {
    var onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            QRScannerView(onFound: onFound)
                .frame(width: 480, height: 380)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: Style.boxCorner))
            Text("Наведи камеру на QR-код")
                .font(.scvpnUI(11))
                .foregroundStyle(Color.scvpnDim)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
            }
        }
        .padding(16)
        .background(Color.scvpnSurface)
    }
}
