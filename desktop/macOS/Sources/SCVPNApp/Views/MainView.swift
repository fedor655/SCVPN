import SCVPNCore
import SwiftUI

/// Главное окно: шапка, кнопка питания, список серверов, лог.
struct MainView: View {
    @ObservedObject var model: AppModel

    /// Лог развёрнут. Не в модели и не в настройках: это состояние взгляда, а
    /// не приложения — разворачивают лог, чтобы посмотреть здесь и сейчас.
    @State private var logExpanded = false

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
                emptyList
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
                // Надпись меняется одновременно с кольцом и тем же
                // растворением: раньше «Подключено» возникало рывком, будто
                // подменили не ту строку.
                .contentTransition(.opacity)
            statusDetail
        }
        .padding(.vertical, Style.powerBlockPadding)
        .frame(maxWidth: .infinity)
        .animation(Style.stateChange, value: model.state)
    }

    /// Подробности под состоянием: строка про «что сейчас» и подпись режима.
    ///
    /// Раньше это была одна строка вида «00:12:34 · системный прокси»: аптайм
    /// и режим — разные по природе вещи, живое число и настройка, — а
    /// разделяла их точка. Теперь режим стоит отдельной подписью и только при
    /// живом подключении: в простое он ничего не сообщает, потому что ничего
    /// ещё не выбрано.
    private var statusDetail: some View {
        VStack(spacing: Style.substatusLineGap) {
            Text(detailLine)
                .font(.substatus)
                .foregroundStyle(Color.scvpnDim)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            if let mode = modeCaption {
                Text(mode)
                    .font(.section)
                    .tracking(Style.sectionTracking)
                    .foregroundStyle(Color.scvpnMuted)
                    .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, Style.substatusPadding)
        .padding(.top, Style.substatusTop)
        .frame(height: Style.substatusHeight, alignment: .top)
    }

    /// Что происходит прямо сейчас: при живом подключении — какой сервер держит
    /// трафик и сколько уже держит, в остальных случаях — куда собирались
    /// подключаться.
    private var detailLine: String {
        switch model.state {
        case .connected:
            // Имя берётся у модели, а не из списка: выбор мог смениться, а
            // туннель остался на прежнем сервере. Разделитель тот же, что на
            // Android и в Qt-версии, — строка обязана читаться одинаково.
            let uptime = formatUptime(model.uptime)
            let name = model.activeServerTitle
            return name.isEmpty ? uptime : "\(name)  ·  \(uptime)"
        case .tunStuck:  return "Трафик всё ещё идёт через туннель"
        default:         return model.selectedServer?.title ?? ""
        }
    }

    private var modeCaption: String? {
        guard model.state == .connected else { return nil }
        return model.mode == .tun ? "ВЕСЬ ТРАФИК" : "СИСТЕМНЫЙ ПРОКСИ"
    }

    /// Пустой список.
    ///
    /// Прежде здесь стояла одна серая фраза посреди пустоты, и экран выглядел
    /// так, будто список не загрузился. Теперь это два разных по весу
    /// сообщения: что произошло и что с этим делать — второе набрано как
    /// подпись, чтобы не спорило с первым.
    private var emptyList: some View {
        VStack(spacing: Style.emptyGap) {
            Text("Серверов пока нет")
                .font(.rowTitle)
                .foregroundStyle(Color.scvpnDim)
            Text("ДОБАВЬ ССЫЛКУ ИЛИ ПОДПИСКУ КНОПКОЙ  +")
                .font(.section)
                .tracking(Style.sectionTracking)
                .foregroundStyle(Color.scvpnMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Style.emptyPadding)
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: Style.listSpacing) {
                ForEach(model.servers, id: \.key) { server in
                    ServerRow(server: server,
                              ping: model.ping(for: server),
                              selected: server.key() == model.selectedKey,
                              last: server.key() == model.servers.last?.key())
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(server) }
                        // Двойной щелчок подключает — так же, как в Qt-версии.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.select(server)
                            model.toggle()
                        })
                }
            }
            // Поля теперь внутри строки: подсветка под курсором должна идти
            // от края до края окна.
            .padding(.bottom, Style.listBottom)
        }
    }

    /// Лог ядра.
    ///
    /// Раньше это была коробка в 130 pt, которая занимала низ окна всегда —
    /// в том числе пустая, пока ядро не запущено. Читают лог ради последней
    /// строки, поэтому по умолчанию видна ровно она; развернуть можно щелчком.
    private var logView: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.scvpnStroke)
                .frame(height: Style.hairline)

            logHeader
            if logExpanded { logBody }
        }
        .background(Color.scvpnSurface)
        .animation(Style.stateChange, value: logExpanded)
    }

    /// Свёрнутая полоса: галочка раскрытия и последняя строка лога.
    private var logHeader: some View {
        Button {
            logExpanded.toggle()
        } label: {
            HStack(spacing: Style.rowGap) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.scvpnMuted)
                    .rotationEffect(.degrees(logExpanded ? 90 : 0))
                Text(model.logLines.last ?? "Лог ядра пуст")
                    .font(.scvpnMono(10))
                    .foregroundStyle(Color.scvpnDim)
                    .lineLimit(1)
                    .truncationMode(.head)   // хвост строки важнее её начала
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Style.listPadding)
            .frame(height: Style.logStripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(logExpanded ? "Свернуть лог" : "Развернуть лог")
    }

    private var logBody: some View {
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
                .padding(.horizontal, Style.listPadding)
                .padding(.bottom, Style.logPadding)
            }
            .frame(height: Style.logHeight)
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
