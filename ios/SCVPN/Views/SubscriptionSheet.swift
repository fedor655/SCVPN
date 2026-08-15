import SCVPNCore
import SwiftUI

/// Список подписок: что прислала панель и когда обновлялось.
///
/// Даты активации в заголовках не бывает, поэтому её здесь нет и выдумывать
/// нечего — показывается ровно то, что пришло.
struct SubscriptionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.subscriptions.isEmpty {
                    Text("Подписок нет")
                        .font(.scvpnUI(13))
                        .foregroundStyle(Color.scvpnDim)
                }
                ForEach(Array(model.subscriptions.enumerated()), id: \.element.url) { _, sub in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sub.name)
                            .font(.scvpnUI(15))
                            .foregroundStyle(Color.scvpnText)
                        Text("серверов \(sub.servers.count) · обновлено \(sub.updated)")
                            .font(.scvpnUI(12))
                            .foregroundStyle(Color.scvpnDim)
                    }
                    .listRowBackground(Color.scvpnSurface)
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
        }
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
