import Combine
import SCVPNCore
import SwiftUI

/// Состояние приложения и всё, что его меняет.
///
/// `ObservableObject`, а не `@Observable`: второй требует macOS 14, а планка
/// проекта — 13.0, и поднимать её ради синтаксиса нельзя.
///
/// Qt-сигналы (`log_signal`, `state_signal`, `tun_state_signal`) заменены
/// обновлением полей на главном потоке: колбэки ядра и демона приходят с чужих
/// потоков, поэтому каждый из них уходит через `MainActor`.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var uptime: Int = 0
    @Published var servers: [Server] = []
    @Published var selectedKey: String = ""
    @Published private(set) var pings: [String: PingResult] = [:]
    @Published private(set) var logLines: [String] = []
    @Published var settings: [String: JSONValue] = [:]
    @Published var showLog = false

    /// Что показать пользователю окном. Ставится моделью, снимается видом.
    @Published var alert: AlertBox?
    /// Какой диалог открыт.
    @Published var sheet: Sheet?
    /// Идёт загрузка: текст шага и доля, если её вообще можно посчитать.
    @Published var download: Download?
    /// Пересчитывается по требованию: файлы на диске меняет не только это
    /// приложение, а SwiftUI перечитывает `body` куда чаще, чем стоит ходить
    /// на диск.
    @Published private(set) var tunPresent = CoreDownloader.tunPresent()
    @Published private(set) var helperInstalled = HelperInstaller.privileged()

    enum Sheet: String, Identifiable {
        case add, splitTunnel, subscriptions
        var id: String { rawValue }
    }

    struct Download {
        var what: String
        var step: String
        /// `nil` — считать нечего, полоска остаётся бегущей.
        ///
        /// Так и задумано: sing-box качает демон, по сокету от него приходят
        /// только строки лога. Байтов мы не видим и выдумывать их не станем.
        var fraction: Double?
    }

    struct AlertBox: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private var profiles = Profiles()
    private var runner: XrayRunner!
    private var tun: Tun!
    /// Пользователь просил подключение. Гасится при любом отказе и при
    /// сознательном отключении — по нему `onState(false)` понимает, падение это
    /// или штатная остановка.
    private var wantConnected = false
    private var connectedSince: Date?
    private var activeSocksPort = 0
    private var activeHTTPPort = 0
    private var clock: AnyCancellable?

    init() {
        settings = loadSettings()
        profiles = loadProfiles()
        servers = profiles.allServers()
        selectedKey = settings["selected_key"]?.stringValue ?? ""
        showLog = settings["show_log"]?.boolValue ?? false

        runner = XrayRunner(
            onLog: { [weak self] line in Task { @MainActor in self?.append(line) } },
            onState: { [weak self] running in Task { @MainActor in self?.onCoreState(running) } }
        )
        tun = Tun(
            onLog: { [weak self] line in Task { @MainActor in self?.append(line) } },
            onState: { [weak self] running in Task { @MainActor in self?.onTunState(running) } }
        )

        // Ядро, пережившее аварийное закрытие приложения, снимаем на старте:
        // про sing-box заботиться не нужно, его стережёт демон.
        if XrayRunner.cleanupStray() {
            append("[*] С прошлого запуска остался xray — убрал.")
        }
    }

    // ------------------------------------------------------------------
    // Настройки и выбор
    // ------------------------------------------------------------------

    var mode: VPNMode {
        VPNMode(rawValue: settings["vpn_mode"]?.stringValue ?? "proxy") ?? .proxy
    }

    var selectedServer: Server? {
        servers.first { $0.key() == selectedKey } ?? servers.first
    }

    func select(_ server: Server) {
        selectedKey = server.key()
        set("selected_key", .string(selectedKey))
        // Ядро уже запущено с прежним конфигом и само не переедет — без этой
        // строки экран показывал бы один сервер, а трафик шёл через другой.
        if state == .connected {
            append("[i] Сервер сменится при следующем подключении")
        }
    }

    func set(_ key: String, _ value: JSONValue) {
        settings[key] = value
        saveSettings(settings)
    }

    func ping(for server: Server) -> PingResult {
        pings[server.key()] ?? .unknown
    }

    func append(_ line: String) {
        logLines.append(line)
        // Потолок тот же, что у Qt-версии: 2000 строк. Лог живёт в памяти всё
        // время работы, а ядро на debug-уровне пишет их тысячами.
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    // ------------------------------------------------------------------
    // Подключение
    // ------------------------------------------------------------------

    func toggle() {
        // Подбор отпечатка уже идёт — не мешаем.
        guard state != .connecting else { return }
        if runner.isRunning { disconnect() } else { connect() }
    }

    func connect() {
        guard let server = selectedServer else {
            alert = .init(title: "Нет сервера",
                          text: "Сначала добавь и выбери сервер из списка.")
            return
        }
        guard CoreDownloader.corePresent() else {
            alert = .init(title: "Нет ядра", text: "Меню «⋯» → «Скачать ядро Xray».")
            return
        }
        // Регистрация демона показывает системный диалог и ждёт согласия
        // пользователя — минуты, если он ушёл в System Settings. На главном
        // потоке это выглядит как зависшее приложение, поэтому TUN-ветка
        // уходит в фон целиком, а экран сразу переключается на «Подключение…».
        if mode == .tun {
            state = .connecting
            append("[*] Проверяю системный компонент…")
            Task { [weak self] in
                guard let self, await self.tunPreflight() else { return }
                self.beginConnect(server)
            }
            return
        }
        beginConnect(server)
    }

    private func beginConnect(_ server: Server) {
        wantConnected = true
        state = .connecting
        append("[*] Подключаюсь к: \(server.title)")

        let override = settings["tls_fingerprint"]?.stringValue ?? "auto"
        let needsFingerprint = ["reality", "tls"].contains(server.security)
        if !needsFingerprint || override != "auto" {
            // Конкретный отпечаток или транспорт без TLS — стартуем сразу.
            start(server, fingerprint: override == "auto" ? "" : override)
            return
        }

        let routeMode = RouteMode(rawValue: settings["route_mode"]?.stringValue ?? "global") ?? .global
        let blockAds = settings["block_ads"]?.boolValue ?? false
        // Слабую ссылку кладём в отдельную константу: замыкание лога уезжает
        // в чужой поток, и захват изменяемого `self?` там — гонка, которую
        // Swift 6 уже считает ошибкой.
        let box = WeakModel(self)
        Task.detached {
            let fp = findWorkingFingerprint(server, override: "auto", routeMode: routeMode,
                                            blockAds: blockAds,
                                            log: { line in box.append(line) })
            await MainActor.run {
                guard let model = box.model, model.wantConnected else { return }
                model.start(server, fingerprint: fp)
            }
        }
    }

    private func start(_ server: Server, fingerprint: String) {
        var srv = server
        if !fingerprint.isEmpty { srv.fingerprint = fingerprint }

        let routeMode = RouteMode(rawValue: settings["route_mode"]?.stringValue ?? "global") ?? .global
        // Свободные порты, чтобы не конфликтовать с другими клиентами.
        let socksPort = findFreePort(preferred: settings["socks_port"]?.intValue ?? defaultSocksPort)
        let httpPort = findFreePort(preferred: max(settings["http_port"]?.intValue ?? defaultHTTPPort,
                                                   socksPort + 1))
        activeSocksPort = socksPort
        activeHTTPPort = httpPort

        do {
            let cfg = try buildXrayConfig(server: srv, socksPort: socksPort, httpPort: httpPort,
                                          routeMode: routeMode,
                                          blockAds: settings["block_ads"]?.boolValue ?? false)
            append("[*] Порты SOCKS=\(socksPort), HTTP=\(httpPort), отпечаток=\(srv.fingerprint)")
            try runner.start(cfg)
        } catch {
            wantConnected = false
            state = .error
            alert = .init(title: "Ошибка запуска ядра", text: "\(error)")
            return
        }

        if mode == .tun {
            do {
                let splitMode = SplitMode(rawValue: settings["split_mode"]?.stringValue ?? "off") ?? .off
                let stack = Stack(rawValue: settings["tun_stack"]?.stringValue ?? "gvisor") ?? .gvisor
                try tun.start(server: srv, socksPort: socksPort, splitMode: splitMode,
                              splitApps: settings["split_apps"]?.stringArray ?? [], stack: stack)
            } catch {
                append("[!] Не удалось включить TUN: \(error)")
                alert = .init(title: "Ошибка TUN", text: "\(error)")
                disconnect()
            }
        } else if settings["system_proxy"]?.boolValue ?? true {
            do {
                try SystemProxy.enable(host: "127.0.0.1", port: httpPort)
                append("[*] Системный прокси включён (127.0.0.1:\(httpPort))")
            } catch {
                append("[!] Не удалось включить системный прокси: \(error)")
            }
        }
    }

    /// Снять с системы всё, что навесило приложение, — на выходе.
    ///
    /// Отдельно от `disconnect()`, потому что здесь не нужны ни лог, ни
    /// состояние, ни тревога про неснятый туннель: окна через мгновение не
    /// будет, показывать некому. Нужен только сам порядок действий.
    ///
    /// Без этого Cmd+Q при живом подключении оставлял в настройках сети
    /// `127.0.0.1:порт`, за которым уже никто не слушает: интернет пропадал во
    /// всей системе, и связать это с закрытым VPN-клиентом было нечем.
    /// Qt-версия убирала за собой в `closeEvent`, при переносе страховку
    /// потеряли.
    func shutdown() {
        wantConnected = false
        _ = tun.stop()
        if SystemProxy.systemProxyIsOurs() { SystemProxy.disable() }
        runner.stop()
    }

    func disconnect() {
        wantConnected = false
        // Сначала TUN — он вернёт маршруты в исходное состояние.
        let tunDown = tun.stop()
        if SystemProxy.systemProxyIsOurs() {
            SystemProxy.disable()
            append("[*] Системный прокси выключён")
        }
        runner.stop()
        // После runner.stop() приходит onCoreState(false), а она рисует «idle»
        // — то самое «Отключено», которое здесь было бы ложью.
        if !tunDown { reportTunStuck() }
    }

    /// Туннель не снялся, и об этом сказал не наш домысел, а сам демон.
    ///
    /// `Tun.stop()` возвращает `false` только по правдивому ответу системного
    /// компонента: sing-box пережил и SIGTERM, и SIGKILL, utun поднят, маршруты
    /// держатся. Показать «Отключено» в этот момент — соврать ровно там, где
    /// правду специально добывали.
    private func reportTunStuck() {
        append("[!] ТРЕВОГА: туннель не снят — sing-box пережил остановку.")
        state = .tunStuck
        alert = .init(title: "Туннель не снят", text: tunStuckText)
    }

    private func onCoreState(_ running: Bool) {
        if running {
            connectedSince = Date()
            startClock()
            state = .connected
            return
        }
        connectedSince = nil
        clock = nil
        uptime = 0
        // Ядро упало само, а мы думали, что подключены — прибираем за ним.
        if wantConnected {
            wantConnected = false
            append("[!] Ядро завершилось само — снимаю остальное.")
            disconnect()
            state = .error
        } else if state != .tunStuck {
            state = .idle
        }
    }

    private func onTunState(_ running: Bool) {
        guard !running, wantConnected else { return }
        // Демон снял sing-box сам: туннеля больше нет, а приложение живо.
        append("[!] Туннель снят системным компонентом.")
        disconnect()
        state = .error
    }

    private func startClock() {
        clock = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let since = self.connectedSince else { return }
                self.uptime = Int(Date().timeIntervalSince(since))
            }
    }

    /// Порядок префлайта на darwin: **сначала права, потом компоненты**.
    ///
    /// Обратный порядок даёт неснимаемый круг на чистой машине: компоненты
    /// кладёт демон, а демона ставит только эта ветка.
    ///
    /// `async` не для красоты: `SMAppService.register()` показывает системный
    /// диалог, а сверка версии ждёт, пока launchd отпустит прежнюю службу — до
    /// десяти секунд. На главном потоке это ровно то зависание, которое
    /// пользователь видит как «приложение повисло».
    private func tunPreflight() async -> Bool {
        if !HelperInstaller.privileged() {
            let result = await Task.detached { HelperInstaller.ensureCurrent() }.value
            switch result {
            case .ready:
                refreshComponents()
            case .awaitingApproval:
                alert = .init(title: "Нужно разрешение", text: """
                    Разреши «SCVPN» в System Settings → General → Login Items \
                    и нажми подключение ещё раз.
                    """)
                HelperInstaller.openSettings()
                state = .idle
                return false
            case .notInstalled:
                alert = .init(title: "Не вышло",
                              text: "Системный компонент не зарегистрировался.")
                state = .idle
                return false
            case .failed(let why):
                alert = .init(title: "Не вышло", text: why)
                state = .idle
                return false
            }
        }
        if !CoreDownloader.tunPresent() {
            alert = .init(title: "Нет компонентов TUN",
                          text: "Меню «⋯» → «Скачать компоненты TUN».")
            state = .idle
            return false
        }
        return true
    }

    // ------------------------------------------------------------------
    // Пинг
    // ------------------------------------------------------------------

    /// Сколько серверов меряем одновременно.
    ///
    /// Каждая проба поднимает своё ядро, поэтому веером пускать нельзя:
    /// десяток `xray` разом — это десяток процессов и десяток пар портов.
    /// Три — компромисс между временем ожидания и нагрузкой.
    ///
    /// `nonisolated`, потому что читается из фоновой задачи замера: значение
    /// постоянное, и запирать его на главном потоке незачем.
    nonisolated private static let pingLanes = 3

    func pingAll() {
        // При живом подключении замер уходит в сам туннель и меряет дорогу до
        // сервера через сервер. Числа получились бы выдуманные, но выглядели
        // бы как настоящие — молчаливого отказа тут мало, нужно объяснение.
        guard state == .idle || state == .error else {
            alert = .init(title: "Сначала отключись",
                          text: "При живом подключении замер идёт через сам туннель, "
                              + "и цифры окажутся выдумкой.")
            return
        }
        let list = servers
        guard !list.isEmpty else {
            alert = .init(title: "Нечего мерить", text: "Сначала добавь серверы.")
            return
        }
        guard CoreDownloader.corePresent() else {
            alert = .init(title: "Нет ядра",
                          text: "Пинг меряется запросом через сам сервер, для этого нужно "
                              + "ядро. Меню «⋯» → «Скачать ядро Xray».")
            return
        }

        append("[*] Меряю пинг \(list.count) серверов…")
        for server in list { pings[server.key()] = .unknown }

        let routeMode = RouteMode(rawValue: settings["route_mode"]?.stringValue ?? "global") ?? .global
        let box = WeakModel(self)
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func submit() {
                    guard next < list.count else { return }
                    let server = list[next]
                    // Своя полоса портов на дорожку: у одновременных проб
                    // иначе совпадает выбранный свободный порт.
                    let portBase = 20000 + (next % Self.pingLanes) * 400
                    next += 1
                    group.addTask {
                        let ms = pingDelay(server, routeMode: routeMode, portBase: portBase)
                        await MainActor.run {
                            box.model?.pings[server.key()] = ms.map(PingResult.ms) ?? .noAnswer
                        }
                    }
                }
                for _ in 0..<min(Self.pingLanes, list.count) { submit() }
                // Освободилась дорожка — сразу занимаем её следующим сервером,
                // а не ждём, пока домерит вся тройка.
                while await group.next() != nil { submit() }
            }
            await MainActor.run { box.model?.append("[*] Пинг завершён.") }
        }
    }

    var subscriptions: [SCVPNCore.Subscription] { profiles.subscriptions }

    func reloadProfiles() {
        profiles = loadProfiles()
        servers = profiles.allServers()
    }

    // ------------------------------------------------------------------
    // Профили и подписки
    // ------------------------------------------------------------------

    /// Добавить одиночный сервер, добавленный ссылкой вручную.
    func addServer(_ server: Server) {
        // Дубликаты отсекаем по тому же ключу, что и обновление подписки:
        // человек вставляет одну и ту же ссылку чаще, чем кажется.
        guard !profiles.allServers().contains(where: { $0.key() == server.key() }) else {
            append("[i] Такой сервер уже есть: \(server.title)")
            return
        }
        profiles.servers.append(server)
        persistProfiles()
        append("[*] Добавлен сервер: \(server.title)")
        if selectedKey.isEmpty { select(server) }
    }

    func addSubscription(url: String) async throws {
        append("[*] Читаю подписку…")
        let (fetched, info) = try await fetchSubscription(url: url)
        var sub = SCVPNCore.Subscription(name: info.title.isEmpty ? (URL(string: url)?.host ?? url) : info.title,
                               url: url, updated: nowISO(), added: nowISO(),
                               info: info, servers: fetched)
        sub.servers = fetched
        profiles.subscriptions.append(sub)
        persistProfiles()
        append("[*] Подписка добавлена: серверов \(fetched.count)")
        if selectedKey.isEmpty, let first = fetched.first { select(first) }
    }

    func removeSubscription(at index: Int) {
        guard profiles.subscriptions.indices.contains(index) else { return }
        let sub = profiles.subscriptions.remove(at: index)
        persistProfiles()
        append("[*] Подписка удалена: \(sub.name)")
    }

    func refreshSubscription(at index: Int) async {
        guard profiles.subscriptions.indices.contains(index) else { return }
        let sub = profiles.subscriptions[index]
        do {
            let (fetched, info) = try await fetchSubscription(url: sub.url)
            // Индекс перечитываем: пока ходили в сеть, список могли поправить.
            guard let now = profiles.subscriptions.firstIndex(where: { $0.url == sub.url }) else { return }
            profiles.subscriptions[now].servers = fetched
            profiles.subscriptions[now].info = info
            profiles.subscriptions[now].updated = nowISO()
            persistProfiles()
            append("[*] \(sub.name): серверов \(fetched.count)")
        } catch {
            append("[!] \(sub.name): \(error)")
            alert = .init(title: "Подписка не обновилась", text: "\(error)")
        }
    }

    func refreshAllSubscriptions() async {
        for index in profiles.subscriptions.indices {
            await refreshSubscription(at: index)
        }
    }

    /// Записать профили и пересобрать список так, чтобы выбор не потерялся.
    private func persistProfiles() {
        saveProfiles(profiles)
        servers = profiles.allServers()
        // Выбранный сервер мог уехать вместе с подпиской: молча оставить
        // ключ, которому ничего не соответствует, значит подключаться потом
        // к первому попавшемуся, ничего не сказав.
        if !servers.contains(where: { $0.key() == selectedKey }) {
            selectedKey = servers.first?.key() ?? ""
            set("selected_key", .string(selectedKey))
        }
    }

    func refreshComponents() {
        tunPresent = CoreDownloader.tunPresent()
        helperInstalled = HelperInstaller.privileged()
    }

    // ------------------------------------------------------------------
    // Компоненты
    // ------------------------------------------------------------------

    func downloadCore() {
        download = Download(what: "ядро Xray", step: "Начинаю…", fraction: nil)
        let box = WeakModel(self)
        Task.detached {
            do {
                let tag = try await CoreDownloader.downloadCore(
                    progress: { line in box.step(line) },
                    onBytes: { got, total in box.bytes(got, total) })
                await MainActor.run {
                    box.model?.download = nil
                    box.model?.refreshComponents()
                    box.model?.alert = .init(title: "Готово",
                                             text: "Ядро Xray-core \(tag) установлено.")
                }
            } catch {
                await MainActor.run {
                    box.model?.download = nil
                    box.model?.append("[!] Не удалось скачать ядро: \(error)")
                    box.model?.alert = .init(title: "Не вышло", text: "\(error)")
                }
            }
        }
    }

    /// Компоненты TUN качает демон: sing-box запускает root, и лежать он обязан
    /// там, куда пользователь писать не может.
    func downloadTun() {
        // Долю не показываем: качает демон, байтов мы не видим.
        download = Download(what: "компоненты TUN", step: "Проверяю системный компонент…", fraction: nil)
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureHelper() else {
                self.download = nil
                return
            }
            self.startSingboxDownload()
        }
    }

    private func startSingboxDownload() {
        let box = WeakModel(self)
        Task.detached {
            do {
                let tag = try installSingboxViaHelper(progress: { line in box.step(line) })
                await MainActor.run {
                    box.model?.download = nil
                    box.model?.refreshComponents()
                    box.model?.alert = .init(title: "Готово",
                                             text: "TUN-компоненты установлены (sing-box \(tag)).")
                }
            } catch {
                await MainActor.run {
                    box.model?.download = nil
                    box.model?.append("[!] Не удалось скачать компоненты TUN: \(error)")
                    box.model?.alert = .init(title: "Не вышло", text: "\(error)")
                }
            }
        }
    }

    /// Удалить sing-box. Системный компонент при этом остаётся: он нужен и для
    /// того, чтобы скачать sing-box обратно.
    ///
    /// Отключаемся первыми: демон и сам откажет живому туннелю, но полагаться
    /// на его отказ значило бы показать пользователю ошибку вместо действия.
    func removeTun() {
        disconnect()
        do {
            let removed = try removeSingboxViaHelper(progress: { [weak self] line in
                Task { @MainActor in self?.append(line) }
            })
            append(removed ? "[*] Компоненты TUN удалены."
                           : "[i] Компоненты TUN и так не были установлены.")
        } catch {
            append("[!] Не удалось удалить компоненты TUN: \(error)")
            alert = .init(title: "Не вышло", text: "\(error)")
        }
        refreshComponents()
    }

    /// Поставить или переставить системный компонент по явной просьбе.
    ///
    /// Отдельный пункт меню нужен потому, что иначе поставить компонент можно
    /// было только «побочно» — попыткой подключиться или скачать sing-box. Тот,
    /// кто его снял, оказывался в тупике: пункт «Удалить» исчезал, а пункта
    /// «Установить» не было вовсе. Текст ошибки в HelperClient при этом
    /// отправлял ровно сюда — «Меню «⋯» → «Переустановить системный компонент»».
    func installHelper() {
        let force = helperInstalled
        append(force ? "[*] Переустанавливаю системный компонент…"
                     : "[*] Ставлю системный компонент…")
        Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached {
                HelperInstaller.ensureCurrent(forceReinstall: force)
            }.value
            self.refreshComponents()
            switch result {
            case .ready:
                self.append("[*] Системный компонент готов.")
            case .awaitingApproval:
                HelperInstaller.openSettings()
                self.alert = .init(title: "Нужно разрешение", text: """
                    Разреши «SCVPN» в System Settings → General → Login Items.
                    """)
            case .notInstalled:
                self.alert = .init(title: "Не вышло",
                                   text: "Системный компонент не зарегистрировался.")
            case .failed(let why):
                self.alert = .init(title: "Не вышло", text: why)
            }
        }
    }

    func removeHelper() {
        disconnect()
        do {
            try HelperInstaller.unregister()
            set("helper_version", .int(0))
            append("[*] Системный компонент снят.")
        } catch {
            append("[!] Не удалось снять системный компонент: \(error)")
            alert = .init(title: "Не вышло", text: "\(error)")
        }
        refreshComponents()
    }

    /// Убедиться, что демон стоит. Компоненты качает он, поэтому без него
    /// «Скачать компоненты TUN» упирается в пустоту.
    private func ensureHelper() async -> Bool {
        if HelperInstaller.privileged() { return true }
        switch await Task.detached(operation: { HelperInstaller.ensureCurrent() }).value {
        case .ready:
            refreshComponents()
            return true
        case .awaitingApproval:
            HelperInstaller.openSettings()
            alert = .init(title: "Нужно разрешение", text: """
                Разреши «SCVPN» в System Settings → General → Login Items \
                и повтори.
                """)
            return false
        case .notInstalled:
            alert = .init(title: "Не вышло", text: "Системный компонент не зарегистрировался.")
            return false
        case .failed(let why):
            alert = .init(title: "Не вышло", text: why)
            return false
        }
    }
}

/// Слабая ссылка на модель, которую можно передать в чужой поток.
///
/// Колбэки ядра и пробы отпечатка приходят откуда угодно, а модель живёт на
/// главном потоке. Захватывать `[weak self]` прямо в такое замыкание нельзя:
/// это захват изменяемой переменной в конкурентном коде, и Swift 6 считает его
/// ошибкой, а не предупреждением. Обёртка делает ссылку неизменяемой, а доступ
/// к модели — явно возвращающим на главный поток.
final class WeakModel: @unchecked Sendable {
    weak var model: AppModel?
    init(_ model: AppModel) { self.model = model }

    func append(_ line: String) {
        Task { @MainActor [model] in model?.append(line) }
    }

    func step(_ line: String) {
        Task { @MainActor [model] in
            model?.append(line)
            model?.download?.step = line
        }
    }

    func bytes(_ got: Int, _ total: Int) {
        guard total > 0 else { return }
        Task { @MainActor [model] in
            model?.download?.fraction = min(1, Double(got) / Double(total))
        }
    }
}
