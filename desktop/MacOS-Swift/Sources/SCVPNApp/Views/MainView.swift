import SCVPNCore
import SwiftUI

/// Главное окно: шапка, кнопка питания, список серверов, лог.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(onPing: model.pingAll,
                       onAdd: { model.sheet = .add },
                       onRefresh: { /* Задача 6.5 */ }) {
                MainMenu(model: model)
            }

            powerBlock

            Text("СЕРВЕРЫ")
                .font(.section)
                .tracking(1.5)
                .foregroundStyle(Color.scvpnDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

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
                .foregroundStyle(Color.scvpnText)
                .padding(.top, 18)
            Text(substatus)
                .font(.substatus)
                .foregroundStyle(Color.scvpnDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 5)
                .frame(height: 32, alignment: .top)
        }
        .padding(.vertical, 24)
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
            LazyVStack(spacing: 4) {
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
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.scvpnMono(10))
                            .foregroundStyle(Color.scvpnDim)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(8)
            }
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.scvpnSurface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.scvpnStroke, lineWidth: 1))
            .padding(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
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
