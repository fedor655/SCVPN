import Combine
import SCVPNCore
import SwiftUI

/// Состояние приложения и всё, что его меняет.
///
/// Устройство то же, что у macOS-версии: поля обновляются на главном потоке,
/// фоновые задачи уходят в `Task`. Разница одна — туннель здесь не наш процесс,
/// а расширение под управлением системы, поэтому «подключено» приходит от неё.
/// Приёмник строк лога из фонового потока.
///
/// `findWorkingFingerprint` зовёт лог с чужого потока, а `append` живёт на
/// главном. Обёртка нужна, чтобы замыкание было `Sendable` и не тащило за собой
/// саму модель.
private struct LogSink: Sendable {
    let write: @Sendable (String) -> Void
    init(_ write: @escaping @Sendable (String) -> Void) { self.write = write }
}

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var uptime: Int = 0
    @Published var servers: [Server] = []
    @Published var selectedKey: String = ""
    @Published private(set) var pings: [String: PingResult] = [:]
    @Published private(set) var logLines: [String] = []
    @Published var settings: [String: JSONValue] = [:]
    @Published var alert: AlertBox?
    @Published var sheet: Sheet?
    @Published private(set) var busy: String?
    /// Сколько прошло через туннель, по данным расширения.
    @Published private(set) var traffic: (up: UInt64, down: UInt64) = (0, 0)
    /// Имя сервера, с которым поднят туннель.
    ///
    /// Экран показывает именно его: выбор в списке можно сменить, сервер
    /// удалить, подписку обновить — туннель от этого не переедет, конфиг уже
    /// у расширения.
    @Published private(set) var activeServerName: String?

    let tunnel = TunnelController()

    /// Состояние экрана — состояние туннеля, кроме короткого промежутка, пока
    /// приложение готовит конфиг: система в этот момент ещё ничего не знает.
    @Published private(set) var preparing = false
    var state: ConnectionState { preparing ? .connecting : tunnel.state }

    enum Sheet: String, Identifiable {
        case add, subscriptions, settings, log
        var id: String { rawValue }
    }

    struct AlertBox: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private var profiles = Profiles()
    private var bag = Set<AnyCancellable>()
    private var connectedSince: Date?
    private var clock: AnyCancellable?
    /// Сколько строк лога расширения уже забрали: оно отдаёт весь свой
    /// кольцевой буфер целиком, и без этого счётчика журнал дублировался бы
    /// каждую секунду.
    private var takenLines = 0

    init() {
        settings = loadSettings()
        profiles = loadProfiles()
        servers = profiles.allServers()
        selectedKey = settings["selected_key"]?.stringValue ?? ""

        // Состояние туннеля живёт в своём объекте, но экран смотрит на модель:
        // без этой пересылки SwiftUI не перерисует кнопку.
        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        tunnel.$state
            .sink { [weak self] state in self?.onTunnelState(state) }
            .store(in: &bag)

        Task { await tunnel.refresh() }
    }

    // ------------------------------------------------------------------
    // Настройки и выбор
    // ------------------------------------------------------------------

    var selectedServer: Server? {
        servers.first { $0.key() == selectedKey } ?? servers.first
    }

    var subscriptions: [SCVPNCore.Subscription] { profiles.subscriptions }

    func select(_ server: Server) {
        selectedKey = server.key()
        set("selected_key", .string(selectedKey))
        // Туннель уже поднят на прежнем сервере, и сам он не переедет: конфиг
        // уехал в расширение при подключении. Без этой строки экран показывал
        // бы один сервер, а трафик шёл через другой.
        if state == .connected { notice("Сервер сменится при следующем подключении") }
    }

    /// Короткое сообщение под статусом. Гаснет само.
    private func notice(_ text: String) {
        busy = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.busy == text { self?.busy = nil }
        }
    }

    func set(_ key: String, _ value: JSONValue) {
        settings[key] = value
        saveSettings(settings)
    }

    func ping(for server: Server) -> PingResult { pings[server.key()] ?? .unknown }

    func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    // ------------------------------------------------------------------
    // Подключение
    // ------------------------------------------------------------------

    func toggle() {
        // Пока идёт наша подготовка (подбор отпечатка, сборка конфига),
        // нажатие игнорируется: отменить её нечем, а отключение по дороге
        // приводило бы к «выключил, а оно подключилось». Так же ведёт себя
        // macOS-версия. Когда состояние пришло от системы — отключаем честно.
        guard !preparing else { return }
        switch state {
        case .connected, .connecting: Task { await disconnect() }
        default: Task { await connect() }
        }
    }

    func connect() async {
        guard var server = selectedServer else {
            alert = .init(title: "Нет сервера",
                          text: "Сначала добавь и выбери сервер из списка.")
            return
        }
        preparing = true
        defer { preparing = false }
        append("[*] Подключаюсь к: \(server.title)")

        // Отпечаток подбирается здесь, а не в расширении: у приложения нет
        // лимита в 50 МБ, а перебор — самая прожорливая операция. В расширение
        // уезжает уже готовое значение.
        let override = settings["tls_fingerprint"]?.stringValue ?? "auto"
        let needsFingerprint = ["reality", "tls"].contains(server.security)
        if needsFingerprint && override != "auto" {
            server.fingerprint = override
        } else if needsFingerprint && XrayBridge.available {
            // Перебор ходит в сеть по разу на кандидата — на главном потоке это
            // выглядит как зависшее приложение.
            // Перебор молчал по полминуты: каждый кандидат — свой таймаут.
            // Строки подбора уходят в журнал по ходу, а не пачкой в конце.
            let candidate = server
            let sink = LogSink { [weak self] line in
                Task { @MainActor in self?.append(line) }
            }
            server.fingerprint = await Task.detached(priority: .userInitiated) {
                findWorkingFingerprint(candidate, override: "auto",
                                       using: XrayBridge(), log: sink.write)
            }.value
            append("[*] Отпечаток: \(server.fingerprint)")
        }

        do {
            // geoAssets: false — гео-баз в расширении нет и не будет: они не
            // помещаются в лимит памяти. Отсюда же и отсутствие «Обхода РФ».
            let cfg = try buildXrayConfig(server: server,
                                          socksPort: defaultSocksPort,
                                          routeMode: .global,
                                          blockAds: false,
                                          logLevel: "warning",
                                          geoAssets: false)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: cfg),
                              as: UTF8.self)
            let config = TunnelConfig(xrayConfigJSON: json,
                                      socksPort: defaultSocksPort,
                                      serverName: server.title)
            activeServerName = server.title
            try await tunnel.start(config: config)
        } catch {
            let text = tunnel.lastError ?? TunnelController.explain(error)
            append("[!] \(text)")
            alert = .init(title: "Не удалось подключиться", text: text)
        }
    }

    func disconnect() async {
        await tunnel.stop()
        append("[*] Отключено")
    }

    private func onTunnelState(_ state: ConnectionState) {
        switch state {
        case .connected:
            if connectedSince == nil {
                connectedSince = Date()
                startClock()
                append("[+] Туннель поднят")
            }
        default:
            connectedSince = nil
            clock = nil
            uptime = 0
            traffic = (0, 0)
            takenLines = 0
            activeServerName = nil
        }
    }

    private func startClock() {
        clock = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let since = self.connectedSince else { return }
                self.uptime = Int(Date().timeIntervalSince(since))
                Task { await self.pollExtension() }
            }
    }

    /// Забрать у расширения счётчики и новые строки лога.
    private func pollExtension() async {
        guard let status = await tunnel.askStatus() else { return }
        traffic = (status.up, status.down)
        if status.lines.count < takenLines { takenLines = 0 }   // расширение перезапустилось
        for line in status.lines.dropFirst(takenLines) { append(line) }
        takenLines = status.lines.count
    }

    // ------------------------------------------------------------------
    // Пинг
    // ------------------------------------------------------------------

    /// Пинг — время установки TCP-соединения, как на десктопе.
    ///
    /// Замер через ядро (`measureOutboundDelay`) честнее — он проверяет и
    /// рукопожатие, — но требует собранного libXray. Пока его нет, TCP-пинг
    /// работает и показывает правду про доступность порта.
    func pingAll() {
        let list = servers
        guard !list.isEmpty else { return }
        append("[*] Меряю пинг \(list.count) серверов…")
        for server in list {
            Task.detached(priority: .utility) {
                let result = tcpPing(host: server.address, port: server.port)
                await MainActor.run { [weak self] in
                    self?.pings[server.key()] = result.map(PingResult.ms) ?? .noAnswer
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Профили и подписки
    // ------------------------------------------------------------------

    func addServer(_ server: Server) {
        guard !profiles.allServers().contains(where: { $0.key() == server.key() }) else {
            append("[i] Такой сервер уже есть: \(server.title)")
            return
        }
        profiles.servers.append(server)
        persistProfiles()
        append("[*] Добавлен сервер: \(server.title)")
        if selectedKey.isEmpty { select(server) }
    }

    /// Разобрать вставленную строку. `false` — не поняли, что это.
    ///
    /// Ответ нужен диалогу: закрывать его при отказе нельзя. SwiftUI глотает
    /// alert, который показывают одновременно с закрытием листа, и человек
    /// видел, что диалог просто исчез, а сервер не появился.
    @discardableResult
    func addFromLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let server = parseLink(trimmed) {
            addServer(server)
            return true
        }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            alert = .init(title: "Не разобрал",
                          text: "Это не ссылка сервера (vless://, vmess://, trojan://, ss://) "
                              + "и не адрес подписки.")
            return false
        }
        Task { await addSubscription(url: trimmed) }
        return true
    }

    func addSubscription(url: String) async {
        busy = "Читаю подписку…"
        defer { busy = nil }
        do {
            let (fetched, info) = try await fetchSubscription(url: url)
            // Панель ответила, но серверов не прислала: сохранять такую
            // подписку незачем — она будет пустой строкой в списке. Android
            // ведёт себя так же.
            guard !fetched.isEmpty else {
                append("[!] В подписке не нашлось серверов")
                alert = .init(title: "Подписка пуста",
                              text: "Панель ответила, но серверов в ответе нет.")
                return
            }
            let title = info.title.isEmpty ? (URL(string: url)?.host ?? url) : info.title

            // Та же ссылка второй раз — это «обновить», а не «добавить ещё
            // одну»: иначе в списке две одинаковые подписки, и серверы каждой
            // живут своей жизнью. Дату добавления сохраняем от первой.
            if let at = profiles.subscriptions.firstIndex(where: { $0.url == url }) {
                profiles.subscriptions[at].servers = fetched
                profiles.subscriptions[at].info = info
                profiles.subscriptions[at].updated = nowISO()
                profiles.subscriptions[at].name = title
            } else {
                profiles.subscriptions.append(
                    SCVPNCore.Subscription(name: title, url: url, updated: nowISO(),
                                           added: nowISO(), info: info, servers: fetched))
            }
            persistProfiles()
            append("[*] Подписка добавлена: серверов \(fetched.count)")
            if selectedKey.isEmpty, let first = fetched.first { select(first) }
        } catch {
            append("[!] \(error)")
            alert = .init(title: "Подписка не добавлена", text: "\(error)")
        }
    }

    func refreshSubscriptions() async {
        guard !profiles.subscriptions.isEmpty else { return }
        busy = "Обновляю подписки…"
        defer { busy = nil }

        // Отказы копим и показываем разом: раньше о них знал только журнал, и
        // нажатие «Обновить» выглядело как «ничего не произошло».
        var failures: [String] = []
        for sub in profiles.subscriptions {
            do {
                let (fetched, info) = try await fetchSubscription(url: sub.url)
                guard let index = profiles.subscriptions.firstIndex(where: { $0.url == sub.url })
                else { continue }
                profiles.subscriptions[index].servers = fetched
                profiles.subscriptions[index].info = info
                profiles.subscriptions[index].updated = nowISO()
                append("[*] \(sub.name): серверов \(fetched.count)")
            } catch {
                append("[!] \(sub.name): \(error)")
                failures.append("\(sub.name)\n\(error)")
            }
        }
        persistProfiles()

        if !failures.isEmpty {
            alert = .init(title: failures.count == 1 ? "Подписка не обновилась"
                                                    : "Подписки не обновились",
                          text: failures.joined(separator: "\n\n"))
        }
    }

    func removeSubscription(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where profiles.subscriptions.indices.contains(index) {
            let sub = profiles.subscriptions.remove(at: index)
            append("[*] Подписка удалена: \(sub.name)")
        }
        persistProfiles()
    }

    func removeServer(at offsets: IndexSet) {
        // Удалять можно только свои: сервер из подписки вернётся при первом же
        // обновлении, и кнопка выглядела бы сломанной.
        let own = profiles.servers
        for index in offsets.sorted(by: >) where own.indices.contains(index) {
            profiles.servers.remove(at: index)
        }
        persistProfiles()
    }

    /// Свои серверы — те, что добавлены ссылкой, а не пришли подпиской.
    var ownServers: [Server] { profiles.servers }

    /// Сервер добавлен вручную, а не пришёл подпиской.
    ///
    /// Удалять можно только свои: сервер подписки вернётся при первом же
    /// обновлении, и кнопка «Удалить» на нём была бы обманом.
    func isOwn(_ server: Server) -> Bool {
        profiles.servers.contains { $0.key() == server.key() }
    }

    func remove(_ server: Server) {
        // Удаление из списка туннель не гасит: конфиг уже у расширения. Без
        // этой оговорки человек думал бы, что убрал сервер вместе с
        // подключением.
        let active = state == .connected && activeServerName == server.title
        profiles.servers.removeAll { $0.key() == server.key() }
        persistProfiles()
        append("[*] Удалён сервер: \(server.title)")
        if active {
            notice("Туннель ещё работает через «\(server.title)»")
        }
    }

    // ------------------------------------------------------------------
    // Перенос профилей
    // ------------------------------------------------------------------

    /// Файл для «Поделиться». Формат общий с Windows, macOS и Android.
    ///
    /// Копия во временной папке, а не сам файл контейнера: лист «Поделиться»
    /// держит ссылку неопределённо долго, а править профиль в это время
    /// приложение имеет полное право.
    func exportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profiles.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(profiles), (try? data.write(to: url)) != nil else {
            alert = .init(title: "Не вышло", text: "Не удалось собрать файл профилей.")
            return nil
        }
        return url
    }

    func importProfiles(from url: URL) {
        // Файл лежит вне песочницы приложения — без этого доступ к нему
        // закрыт, и чтение вернёт «нет прав» вместо содержимого.
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let incoming = try? JSONDecoder().decode(Profiles.self, from: data) else {
            alert = .init(title: "Не разобрал файл",
                          text: "Это не файл профилей SCVPN.")
            return
        }
        guard !incoming.allServers().isEmpty || !incoming.subscriptions.isEmpty else {
            alert = .init(title: "Файл пуст",
                          text: "В нём нет ни серверов, ни подписок.")
            return
        }
        let before = profiles.allServers().count
        profiles = mergeProfiles(profiles, incoming)
        persistProfiles()
        let added = profiles.allServers().count - before
        append("[*] Загружено серверов: \(added)")
        alert = .init(title: "Готово", text: added > 0
                      ? "Добавлено серверов: \(added)."
                      : "Всё из этого файла уже было.")
    }

    private func persistProfiles() {
        saveProfiles(profiles)
        servers = profiles.allServers()
        if !servers.contains(where: { $0.key() == selectedKey }) {
            selectedKey = servers.first?.key() ?? ""
            set("selected_key", .string(selectedKey))
        }
    }
}
