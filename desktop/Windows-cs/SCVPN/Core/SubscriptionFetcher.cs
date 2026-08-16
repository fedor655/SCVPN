using System.Net;
using System.Net.Http;

namespace SCVPN.Core;

/// <summary>Подписка ответила, но серверов не отдала — и объяснила почему.</summary>
public sealed class SubscriptionException : Exception
{
    public SubscriptionException(string message) : base(message) { }
}

public sealed class SubscriptionResult
{
    public List<Server> Servers { get; set; } = new();
    public SubscriptionInfo Info { get; set; } = new();
}

public static class SubscriptionFetcher
{
    /// <summary>
    /// Многие панели (3x-ui, Marzban, Remnawave) отдают список ссылок в base64,
    /// ориентируясь на User-Agent известного клиента.
    ///
    /// <b>Не менять.</b> По этому значению панели решают, отдать список
    /// <c>vless://</c>-ссылок или clash-конфиг, который мы не разбираем.
    /// </summary>
    public const string DefaultUserAgent = "v2rayNG/1.9.5";

    private const int TimeoutSeconds = 30;

    // Один экземпляр на всё приложение: новый HttpClient на каждое обновление
    // подписки съедает сокеты (они висят в TIME_WAIT), а обновлений за сессию
    // бывает много. Хендлер разжимает ответ сам — панели отдают gzip, если
    // клиент похож на настоящий, а мы им как раз и представляемся.
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        HttpClientHandler handler = new()
        {
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        };
        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(TimeoutSeconds) };
    }

    /// <summary>
    /// Скачать подписку и разобрать её.
    ///
    /// Кроме User-Agent шлём идентификатор устройства: панели с привязкой к
    /// устройствам без него отдают заглушку вместо серверов.
    /// </summary>
    public static async Task<SubscriptionResult> FetchAsync(
        string url,
        IReadOnlyDictionary<string, string> deviceHeaders,
        string userAgent = DefaultUserAgent,
        CancellationToken ct = default)
    {
        // Схему и хост проверяем сами, до сети: иначе «vpn.example.com» без
        // протокола или случайная строка из буфера обмена доходили бы до
        // запроса и пользователь получал бы «домен заблокирован» вместо
        // «это не ссылка».
        if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? target)
            || (target.Scheme != Uri.UriSchemeHttp && target.Scheme != Uri.UriSchemeHttps)
            || string.IsNullOrEmpty(target.Host))
        {
            throw new SubscriptionException("Это не похоже на ссылку подписки: " + url);
        }

        using HttpRequestMessage request = new(HttpMethod.Get, target);
        // TryAddWithoutValidation, а не Add: User-Agent правится в настройках, и
        // строка, которую HttpClient считает невалидной, не должна ронять
        // обновление исключением о заголовке.
        request.Headers.TryAddWithoutValidation("User-Agent", userAgent);
        foreach (KeyValuePair<string, string> kv in deviceHeaders)
            request.Headers.TryAddWithoutValidation(kv.Key, kv.Value);

        HttpResponseMessage response;
        try
        {
            response = await Http.SendAsync(request, HttpCompletionOption.ResponseContentRead, ct)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Отмену пользователем не переодеваем в ошибку подписки — окно
            // само знает, что оно её и запросило.
            throw;
        }
        catch (Exception)
        {
            // Частый случай: домен провайдера подписки заблокирован, а сами его
            // VPN-серверы доступны. Получается замкнутый круг — подписку не
            // обновить без VPN, а VPN не включить без серверов. Обычная ошибка
            // сети об этом не говорит, поэтому объясняем прямо.
            // Сюда же попадает таймаут: HttpClient сообщает о нём той же
            // TaskCanceledException, и для пользователя это тот же случай.
            throw new SubscriptionException(
                "Не удалось связаться с сайтом подписки (" + target.Host + ").\n\n" +
                "Чаще всего это значит, что домен провайдера заблокирован, — сами " +
                "VPN-серверы при этом обычно работают.\n\n" +
                "Что делать: подключись к любому уже добавленному серверу и нажми " +
                "«Обновить» ещё раз. Если серверов нет ни одного — добавь один " +
                "ссылкой vless:// или отсканируй QR.");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                // Код ответа пользователю показать надо: 401/403 у панели
                // означают «ссылка протухла», а не поломку клиента.
                // Python и Swift пишут ровно так же — тексты обязаны совпадать.
                throw new SubscriptionException(
                    "Подписка ответила кодом " + ((int)response.StatusCode) + ".");
            }

            string text = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            Dictionary<string, string> headers = CollectHeaders(response);

            List<Server> servers = LinkParser.ParseSubscriptionText(text);
            RaiseIfPanelStub(servers, headers);
            return new SubscriptionResult
            {
                Servers = servers,
                Info = SubscriptionInfo.FromHeaders(headers),
            };
        }
    }

    /// <summary>
    /// Заголовки ответа одним словарём с ключами в нижнем регистре.
    ///
    /// HttpClient делит их надвое: content-disposition, от которого зависит имя
    /// аккаунта, лежит не в <c>Headers</c>, а в <c>Content.Headers</c>. Разбор
    /// сведений о подписке ждёт их вместе, как их и прислала панель.
    /// </summary>
    private static Dictionary<string, string> CollectHeaders(HttpResponseMessage response)
    {
        Dictionary<string, string> map = new(StringComparer.Ordinal);
        foreach (KeyValuePair<string, IEnumerable<string>> kv in response.Headers)
            map[kv.Key.ToLowerInvariant()] = string.Join(", ", kv.Value);
        foreach (KeyValuePair<string, IEnumerable<string>> kv in response.Content.Headers)
            map[kv.Key.ToLowerInvariant()] = string.Join(", ", kv.Value);
        return map;
    }

    /// <summary>
    /// Отличить заглушку панели от настоящего списка серверов.
    ///
    /// Панель не возвращает ошибку HTTP: она отдаёт один фиктивный
    /// <c>vless://0000…@0.0.0.0:1</c>, у которого в имени написана причина. Без
    /// этой проверки такая строка молча попадала бы в список серверов — ровно
    /// это и выглядело как «сервер App not supported», к которому нельзя
    /// подключиться.
    /// </summary>
    public static void RaiseIfPanelStub(
        IReadOnlyList<Server> servers,
        IReadOnlyDictionary<string, string> headers)
    {
        List<Server> stub = new();
        foreach (Server s in servers)
            if (s.Address is "0.0.0.0" or "127.0.0.1" or "" || s.Port <= 1)
                stub.Add(s);

        // Заглушкой считаем только ответ, состоящий из неё целиком: один мёртвый
        // сервер среди живых — это не сообщение панели, а просто мёртвый сервер.
        if (servers.Count == 0 || stub.Count != servers.Count) return;

        string reason = stub[0].Name.Trim();
        // Здесь, в отличие от SubscriptionInfo, к нижнему регистру приводятся и
        // значения: панели пишут флаг и как "true", и как "True".
        Dictionary<string, string> lower = new(StringComparer.Ordinal);
        foreach (KeyValuePair<string, string> kv in headers)
            lower[kv.Key.ToLowerInvariant()] = kv.Value.ToLowerInvariant();

        if (lower.TryGetValue("x-hwid-max-devices-reached", out string? reached) && reached == "true")
        {
            throw new SubscriptionException(
                "Достигнут лимит устройств на аккаунте (" +
                (reason.Length == 0 ? "limit of devices reached" : reason) + ").\n\n" +
                "Освободи слот в личном кабинете подписки или у поддержки провайдера, " +
                "затем нажми «Обновить» ещё раз.");
        }
        if (lower.TryGetValue("x-hwid-not-supported", out string? unsupported) && unsupported == "true")
        {
            throw new SubscriptionException(
                "Панель не приняла идентификатор устройства.\n\n" +
                "Похоже, у провайдера включена привязка к устройствам, а клиент " +
                "представился неверно. Сообщи об этом — это чинится в SCVPN.");
        }
        throw new SubscriptionException(
            "Подписка вернула не список серверов, а сообщение: «" +
            (reason.Length == 0 ? "без пояснения" : reason) + "».");
    }
}
