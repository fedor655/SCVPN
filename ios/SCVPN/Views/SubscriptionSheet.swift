import SCVPNCore
import SwiftUI

/// Список подписок: что прислала панель и когда обновлялось.
///
/// Даты активации в заголовках не бывает, поэтому её здесь нет и выдумывать
/// нечего — показывается ровно то, что пришло.
struct SubscriptionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Какая подписка раскрыта. Ссылку и QR показываем по требованию: экран не
    /// должен быть простынёй, если подписок несколько.
    @State private var shown: String?
    /// Какую ссылку отправляем — открывает системный лист «Поделиться».
    @State private var sharing: String?

    var body: some View {
        NavigationStack {
            List {
                if model.subscriptions.isEmpty {
                    Text("Подписок нет")
                        .font(.scvpnUI(13))
                        .foregroundStyle(Color.scvpnDim)
                        .listRowBackground(Color.scvpnSurface)
                }
                ForEach(model.subscriptions, id: \.url) { sub in
                    Section {
                        card(sub)
                    }
                }
                .onDelete { model.removeSubscription(at: $0) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.scvpnBG)
            .navigationTitle("Подписки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Обновить") { Task { await model.refreshSubscriptions() } }
                        .disabled(model.subscriptions.isEmpty)
                }
            }
            // Лист перекрывает главный экран, поэтому его alert не виден:
            // отказ обновления показываем здесь же.
            .alert(item: $model.alert) { box in
                Alert(title: Text(box.title), message: Text(box.text),
                      dismissButton: .default(Text("Понятно")))
            }
            .sheet(item: Binding(get: { sharing.map(ShareItem.init) },
                                 set: { sharing = $0?.text })) { item in
                ShareText(text: item.text, title: "Ссылка подписки SCVPN")
            }
        }
    }

    /// Карточка одной подписки: то же, что показывает Android.
    @ViewBuilder
    private func card(_ sub: SCVPNCore.Subscription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sub.name.isEmpty ? sub.url : sub.name)
                .font(.scvpnUI(15, weight: .bold))
                .foregroundStyle(Color.scvpnText)

            line("Серверов", "\(sub.servers.count)")
            line("Трафик", traffic(sub.info))
            line("Действует до", expiry(sub.info))
            if sub.info.updateInterval > 0 {
                line("Автообновление", humanInterval(sub.info.updateInterval))
            }
            if !sub.updated.isEmpty { line("Обновлено", sub.updated) }
            if !sub.info.announce.isEmpty {
                Text(sub.info.announce)
                    .font(.scvpnUI(12))
                    .foregroundStyle(Color.scvpnDim)
            }

            HStack(spacing: 16) {
                Button("Копировать") { UIPasteboard.general.string = sub.url }
                Button("Поделиться") { sharing = sub.url }
                Button(shown == sub.url ? "Скрыть QR" : "QR") {
                    shown = shown == sub.url ? nil : sub.url
                }
            }
            .font(.scvpnUI(13))
            .padding(.top, 2)

            if shown == sub.url {
                // Ссылка подписки — это доступ к аккаунту целиком, поэтому она
                // и QR показываются только по нажатию, а не сами собой.
                QRCodeImage(text: sub.url)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                Text(sub.url)
                    .font(.scvpnMono(10))
                    .foregroundStyle(Color.scvpnDim)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.scvpnSurface)
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
        }
        .font(.scvpnUI(12))
        .foregroundStyle(Color.scvpnDim)
    }

    private func traffic(_ info: SubscriptionInfo) -> String {
        info.unlimited ? "\(humanBytes(info.used)) (без лимита)"
                       : "\(humanBytes(info.used)) из \(humanBytes(info.total))"
    }

    private func expiry(_ info: SubscriptionInfo) -> String {
        guard let days = info.daysLeft else { return "бессрочно" }
        return days < 0 ? "истекла" : "\(days) дн."
    }
}

/// Журнал приложения. Полноценного лога ядра на iOS нет: расширение живёт в
/// лимите памяти, и оттуда приходит только хвост последних строк.
struct LogSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if model.logLines.isEmpty {
                        Text("Пока пусто — здесь появятся строки о подключении.")
                            .font(.scvpnUI(13))
                            .foregroundStyle(Color.scvpnDim)
                            .padding(.top, 24)
                    }
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.scvpnMono(11))
                            .foregroundStyle(Color.scvpnDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            .background(Color.scvpnBG)
            .navigationTitle("Журнал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}

/// Обёртка, чтобы строку можно было отдать `sheet(item:)`.
private struct ShareItem: Identifiable {
    let text: String
    var id: String { text }
}
