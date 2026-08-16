import SCVPNCore
import SwiftUI

/// Главное окно: шапка, кнопка питания, список серверов, лог.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(onPing: model.pingAll,
                       onAdd: { model.sheet = .add },
                       onRefresh: { Task { await model.refreshAllSubscriptions() } }) {
                MainMenu(model: model)
            }

            // Полосы заголовка у окна нет, и без этой линии шапка сливалась с
            // содержимым: непонятно, где кончаются кнопки окна и начинается
            // приложение.
            Rectangle()
                .fill(Color.scvpnStroke)
                .frame(height: Style.hairline)

            powerBlock

            Text("СЕРВЕРЫ")
                .font(.section)
                .tracking(Style.sectionTracking)
                .foregroundStyle(Color.scvpnDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Style.sectionPadding)
                .padding(.bottom, Style.sectionBottom)

            if model.servers.isEmpty {
                Text("Серверов пока нет.\nДобавь ссылку или подписку кнопкой  +")
                    .font(.substatus)
                    .foregroundStyle(Color.scvpnDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                serverList
            }

            if model.showLog { logView }
        }
        .background(Color.scvpnBG)
        .sheet(item: Binding(
            get: { model.download.map { DownloadBox(download: $0) } },
            set: { _ in }   // закрывается только по завершении, отмены нет
        )) { box in
            ProgressSheet(download: box.download)
        }
        .sheet(item: $model.sheet) { which in
            switch which {
            case .add:          AddSheet(model: model)
            case .splitTunnel:  SplitTunnelSheet(model: model)
            case .subscriptions: SubscriptionSheet(model: model)
            }
        }
        .alert(item: $model.alert) { box in
            Alert(title: Text(box.title), message: Text(box.text),
                  dismissButton: .default(Text("Ясно")))
        }
    }

    private var powerBlock: some View {
        VStack(spacing: 0) {
            PowerButton(state: model.state, action: model.toggle)
            Text(model.state.title)
                .font(.statusBig)
                .tracking(Style.statusTracking)
                .foregroundStyle(Color.scvpnText)
                .padding(.top, Style.statusTop)
            Text(substatus)
                .font(.substatus)
                .foregroundStyle(Color.scvpnDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Style.substatusPadding)
                .padding(.top, Style.substatusTop)
                .frame(height: Style.substatusHeight, alignment: .top)
        }
        .padding(.vertical, Style.powerBlockPadding)
        .frame(maxWidth: .infinity)
    }

    private var substatus: String {
        switch model.state {
        case .connected:
            let mode = model.mode == .tun ? "весь трафик" : "системный прокси"
            return "\(formatUptime(model.uptime)) · \(mode)"
        case .connecting:
            return model.selectedServer?.title ?? ""
        case .tunStuck:
            return "Трафик всё ещё идёт через туннель"
        default:
            return model.selectedServer?.title ?? ""
        }
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: Style.listSpacing) {
                ForEach(model.servers, id: \.key) { server in
                    ServerRow(server: server,
                              ping: model.ping(for: server),
                              selected: server.key() == model.selectedKey)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(server) }
                        // Двойной щелчок подключает — так же, как в Qt-версии.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.select(server)
                            model.toggle()
                        })
                }
            }
            .padding(.horizontal, Style.listPadding)
            .padding(.bottom, Style.listBottom)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Style.logLineSpacing) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.scvpnMono(10))
                            .foregroundStyle(Color.scvpnDim)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(Style.logPadding)
            }
            .frame(height: Style.logHeight)
            .background(RoundedRectangle(cornerRadius: Style.logCorner).fill(Color.scvpnSurface))
            .overlay(RoundedRectangle(cornerRadius: Style.logCorner)
                .stroke(Color.scvpnStroke, lineWidth: Style.stroke))
            .padding(Style.logInsets)
            .onChange(of: model.logLines.count) { count in
                // Лог читают ради последней строки — держим её в виду.
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

/// `Server` не `Identifiable` по построению: в `profiles.json` нет и не должно
/// быть искусственного идентификатора. Для списка хватает ключа, которым и так
/// отсеиваются дубликаты подписки.
extension Server {
    var key: String { key() }
}

/// Обёртка, чтобы окно загрузки можно было показать через `sheet(item:)`.
///
/// Идентификатор постоянный: смена шага не должна пересоздавать окно.
struct DownloadBox: Identifiable {
    let id = "download"
    let download: AppModel.Download
}
