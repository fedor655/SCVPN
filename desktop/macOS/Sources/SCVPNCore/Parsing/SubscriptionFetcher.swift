import Foundation

/// Многие панели (3x-ui, Marzban, Remnawave) отдают список ссылок в base64,
/// ориентируясь на User-Agent известного клиента.
///
/// **Не менять.** По этому значению панели решают, отдать список
/// `vless://`-ссылок или clash-конфиг, который мы не разбираем.
public let defaultUserAgent = "v2rayNG/1.9.5"

/// Подписка ответила, но серверов не отдала — и объяснила почему.
public struct SubscriptionError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

/// Отличить заглушку панели от настоящего списка серверов.
///
/// Панель не возвращает ошибку HTTP: она отдаёт один фиктивный
/// `vless://0000…@0.0.0.0:1`, у которого в имени написана причина. Без этой
/// проверки такая строка молча попадала бы в список серверов — ровно это и
/// выглядело как «сервер App not supported», к которому нельзя подключиться.
public func raiseIfPanelStub(_ servers: [Server], headers: [AnyHashable: Any]) throws {
    let stub = servers.filter {
        ["0.0.0.0", "127.0.0.1", ""].contains($0.address) || $0.port <= 1
    }
    // Заглушкой считаем только ответ, состоящий из неё целиком: один мёртвый
    // сервер среди живых — это не сообщение панели, а просто мёртвый сервер.
    guard !servers.isEmpty, stub.count == servers.count else { return }

    let reason = stub[0].name.trimmingCharacters(in: .whitespaces)
    var lower: [String: String] = [:]
    for (k, v) in headers { lower["\(k)".lowercased()] = "\(v)".lowercased() }

    if lower["x-hwid-max-devices-reached"] == "true" {
        throw SubscriptionError("""
            Достигнут лимит устройств на аккаунте (\(reason.isEmpty ? "limit of devices reached" : reason)).

            Освободи слот в личном кабинете подписки или у поддержки провайдера, \
            затем нажми «Обновить» ещё раз.
            """)
    }
    if lower["x-hwid-not-supported"] == "true" {
        throw SubscriptionError("""
            Панель не приняла идентификатор устройства.

            Похоже, у провайдера включена привязка к устройствам, а клиент \
            представился неверно. Сообщи об этом — это чинится в SCVPN.
            """)
    }
    throw SubscriptionError(
        "Подписка вернула не список серверов, а сообщение: «\(reason.isEmpty ? "без пояснения" : reason)».")
}

/// Скачать подписку и разобрать её.
///
/// Кроме User-Agent шлём идентификатор устройства: панели с привязкой к
/// устройствам без него отдают заглушку вместо серверов.
public func fetchSubscription(
    url: String,
    userAgent: String = defaultUserAgent,
    timeout: TimeInterval = 30
) async throws -> (servers: [Server], info: SubscriptionInfo) {
    // Схему и хост проверяем сами. `URL(string:)` их не требует: на macOS 26
    // он принимает «не ссылка» как относительный путь, и до сети дело доходит
    // с пустым хостом — пользователь получал бы «домен заблокирован» вместо
    // «это не ссылка».
    guard let target = URL(string: url),
          let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
          !(target.host ?? "").isEmpty else {
        throw SubscriptionError("Это не похоже на ссылку подписки: \(url)")
    }
    var request = URLRequest(url: target, timeoutInterval: timeout)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (k, v) in deviceHeaders() { request.setValue(v, forHTTPHeaderField: k) }

    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        // Частый случай: домен провайдера подписки заблокирован, а сами его
        // VPN-серверы доступны. Получается замкнутый круг — подписку не
        // обновить без VPN, а VPN не включить без серверов. Обычная ошибка
        // сети об этом не говорит, поэтому объясняем прямо.
        throw SubscriptionError("""
            Не удалось связаться с сайтом подписки (\(target.host ?? url)).

            Чаще всего это значит, что домен провайдера заблокирован, — сами \
            VPN-серверы при этом обычно работают.

            Что делать: подключись к любому уже добавленному серверу и нажми \
            «Обновить» ещё раз. Если серверов нет ни одного — добавь один \
            ссылкой vless:// или отсканируй QR.
            """)
    }

    guard let http = response as? HTTPURLResponse else {
        throw SubscriptionError("Подписка ответила не по HTTP.")
    }
    guard (200...299).contains(http.statusCode) else {
        throw SubscriptionError("Подписка ответила кодом \(http.statusCode).")
    }

    let text = String(decoding: data, as: UTF8.self)
    let servers = parseSubscriptionText(text)
    try raiseIfPanelStub(servers, headers: http.allHeaderFields)
    return (servers, subscriptionInfo(from: http.allHeaderFields))
}
