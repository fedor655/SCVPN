import SCVPNCore
import SwiftUI

/// Единственный экран: знак, кнопка, статус, список серверов.
///
/// Состав тот же, что у Android-версии (`MainActivity.kt`) и у macOS-окна —
/// три платформы должны называть вещи одинаково.
struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    PowerButton(state: model.state) { model.toggle() }
                        .padding(.top, 12)

                    VStack(spacing: 4) {
                        Text(model.state.title)
                            .font(.statusBig)
                            .foregroundStyle(Color.scvpnText)
                        Text(substatus)
                            .font(.substatus)
                            .foregroundStyle(Color.scvpnDim)
                            .multilineTextAlignment(.center)
                    }

                    if let busy = model.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Color.scvpnDim)
                            Text(busy).font(.scvpnUI(12)).foregroundStyle(Color.scvpnDim)
                        }
                    }

                    subscriptionCard

                    serverList
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.scvpnBG)
            .scrollContentBackground(.hidden)
            .navigationTitle("SCVPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .tint(Color.scvpnText)
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .add: AddSheet()
                case .subscriptions: SubscriptionSheet()
                case .settings: SettingsSheet()
                case .log: LogSheet()
                }
            }
            // Диалог заводит своё окружение, и цвет из корня в него не
            // попадает: без этой строки кнопки диалогов синие, а тема
            // чёрно-белая. Окружение модели по той же причине пробрасывается
            // явно.
            .tint(Color.scvpnText)
            .environmentObject(model)
            .preferredColorScheme(.dark)
        }
        .alert(item: $model.alert) { box in
            Alert(title: Text(box.title), message: Text(box.text),
                  dismissButton: .default(Text("Понятно")))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { model.sheet = .add } label: { Image(systemName: "plus") }
                .accessibilityLabel("Добавить сервер или подписку")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Обновить подписки") { Task { await model.refreshSubscriptions() } }
                Button("Померить пинг") { model.pingAll() }
                Divider()
                Button("Подписки") { model.sheet = .subscriptions }
                Button("Настройки") { model.sheet = .settings }
                Button("Журнал") { model.sheet = .log }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Меню")
        }
    }

    private var substatus: String {
        switch model.state {
        case .connected:
            // Имя того сервера, с которым поднят туннель, а не выбранного в
            // списке: список мог измениться, туннель — нет.
            let name = model.activeServerName ?? model.selectedServer?.title ?? ""
            // humanBytes считает в Int — он же используется для трафика
            // подписки, и разнобой в единицах на одном экране был бы хуже
            // потери точности на числах такого размера.
            let up = Int(clamping: model.traffic.up), down = Int(clamping: model.traffic.down)
            let counters = up + down > 0 ? " · ↑\(humanBytes(up)) ↓\(humanBytes(down))" : ""
            return "\(name) · \(formatUptime(model.uptime))\(counters)"
        case .connecting: return "Поднимаю туннель…"
        case .error: return "Смотри журнал: меню «⋯» → «Журнал»"
        default:
            return model.servers.isEmpty ? "Добавь сервер или подписку"
                                         : (model.selectedServer?.title ?? "")
        }
    }

    @ViewBuilder
    private var subscriptionCard: some View {
        if let sub = model.subscriptions.first {
            VStack(alignment: .leading, spacing: 6) {
                Text(sub.name)
                    .font(.scvpnUI(13, weight: .bold))
                    .foregroundStyle(Color.scvpnText)
                HStack {
                    Text(trafficLine(sub.info))
                    Spacer()
                    Text(expiryLine(sub.info))
                }
                .font(.scvpnUI(12))
                .foregroundStyle(Color.scvpnDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.scvpnSurface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.scvpnStroke))
        }
    }

    private func trafficLine(_ info: SubscriptionInfo) -> String {
        info.unlimited ? "Трафик: без лимита"
                       : "Трафик: \(humanBytes(info.used)) из \(humanBytes(info.total))"
    }

    private func expiryLine(_ info: SubscriptionInfo) -> String {
        guard let days = info.daysLeft else { return "Бессрочно" }
        return "Осталось дней: \(days)"
    }

    @ViewBuilder
    private var serverList: some View {
        if model.servers.isEmpty {
            Text("Серверов пока нет")
                .font(.scvpnUI(13))
                .foregroundStyle(Color.scvpnDim)
                .padding(.top, 24)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("СЕРВЕРЫ")
                    .font(.section)
                    .foregroundStyle(Color.scvpnMuted)
                    .padding(.leading, 4)
                // id по ключу сервера, а не по индексу: список перетряхивается
                // после каждого обновления подписки.
                ForEach(model.servers) { server in
                    ServerRow(server: server,
                              ping: model.ping(for: server),
                              selected: server.key() == model.selectedKey)
                        .onTapGesture { model.select(server) }
                        .contextMenu {
                            if model.isOwn(server) {
                                Button("Удалить", role: .destructive) { model.remove(server) }
                            } else {
                                // Сервер подписки вернётся при первом же
                                // обновлении — удалять его поштучно бессмысленно.
                                Text("Из подписки — удаляется вместе с ней")
                            }
                        }
                }
            }
        }
    }
}
