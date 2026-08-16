using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace SCVPN.Core;

/// <summary>
/// Автоподбор рабочего TLS-отпечатка (fingerprint) для Reality/TLS и замер
/// задержки через сам сервер.
///
/// Зачем: в свежих сборках Xray отпечаток chrome шлёт пост-квантовую кривую
/// (X25519MLKEM768), которую часть серверов не понимает — соединение виснет.
/// А fp=randomized выбирает отпечаток случайно, поэтому коннект нестабильный.
///
/// Чтобы «просто работало», при подключении мы по-быстрому проверяем несколько
/// отпечатков на реальном сервере и берём первый рабочий. Проверка — это
/// короткий HTTPS-запрос через временный локальный прокси (ходит только на
/// api.ipify.org).
/// </summary>
public static class FingerprintProbe
{
    public const string ProbeUrl = "https://api.ipify.org";

    /// <summary>
    /// Куда ходит замер пинга.
    ///
    /// Не <see cref="ProbeUrl"/>: 204-й ответ пустой, и в измеренное время не
    /// попадает ни тело, ни его разбор — остаётся то, ради чего замер и
    /// делается. Тот же адрес используют Android и macOS, поэтому числа на
    /// трёх платформах сравнимы между собой.
    /// </summary>
    public const string PingUrl = "https://www.gstatic.com/generate_204";

    /// <summary>
    /// Сколько отпечатков перебирать при замере.
    ///
    /// Меньше, чем при подключении: там перебор идёт один раз и ради того,
    /// чтобы соединение вообще состоялось, а здесь — по каждому серверу
    /// списка, и цена умножается на их число.
    /// </summary>
    public const int PingFpTries = 3;

    /// <summary>
    /// Порядок проверки: сперва те, что не шлют пост-квантовых кривых.
    ///
    /// <b>Порядок не менять.</b> В свежих сборках Xray отпечаток chrome шлёт
    /// X25519MLKEM768, которую часть серверов не понимает — соединение виснет.
    /// randomized выбирает отпечаток случайно, отчего коннект нестабилен, и
    /// поэтому стоит последним.
    /// </summary>
    public static readonly string[] FallbackFingerprints =
        new[] { "firefox", "chrome", "safari", "edge", "ios", "randomized" };

    /// <summary>Отпечатки для проверки в порядке предпочтения.</summary>
    public static List<string> Candidates(Server server, string overrideValue)
    {
        if (!string.IsNullOrEmpty(overrideValue) && overrideValue != "auto")
        {
            // Пользователь выбрал конкретный — без подбора.
            return new List<string> { overrideValue };
        }

        var candidates = new List<string>();
        // ToLowerInvariant, а не ToLower: при турецкой локали "IOS".ToLower()
        // даёт "ıos", и такой отпечаток не совпал бы ни с одним из запасных.
        var fp = (server.Fingerprint ?? string.Empty).ToLowerInvariant();
        // Отпечаток из подписки идёт первым, но только если он конкретный:
        // randomized означает «панель не знает», а не «панель просит случайный».
        if (fp.Length > 0 && fp != "randomized" && fp != "random")
        {
            candidates.Add(fp);
        }
        foreach (var f in FallbackFingerprints)
        {
            if (!candidates.Contains(f))
            {
                candidates.Add(f);
            }
        }
        return candidates;
    }

    /// <summary>
    /// Первый рабочий отпечаток. Если ни один не прошёл — первый кандидат:
    /// лучше попробовать подключиться заведомым кандидатом, чем не пробовать
    /// вовсе.
    /// </summary>
    public static async Task<string> FindWorkingAsync(Server server, string overrideValue, string routeMode,
        bool blockAds, Action<string>? log, double perProbeTimeoutSeconds = 6.0, CancellationToken ct = default)
    {
        var candidates = Candidates(server, overrideValue);
        // Конкретный выбор пользователя не проверяем: он его и просил.
        if (candidates.Count == 1)
        {
            return candidates[0];
        }

        log?.Invoke("[*] Подбираю рабочий TLS-отпечаток…");
        foreach (var fp in candidates)
        {
            if (await ProbeAsync(server, fp, routeMode, blockAds, perProbeTimeoutSeconds, ct).ConfigureAwait(false))
            {
                log?.Invoke("[+] Рабочий отпечаток: " + fp);
                return fp;
            }
            log?.Invoke("    " + fp + " — не подошёл");
        }
        log?.Invoke("[!] Ни один отпечаток не прошёл проверку, пробую первый.");
        return candidates[0];
    }

    /// <summary>
    /// Задержка до сервера с перебором отпечатков — то, что показывает колонка
    /// пинга.
    ///
    /// Отдельно от <see cref="XrayDelayAsync"/>, потому что у панелей сплошь и
    /// рядом стоит fingerprint=randomized, а это значит «панель не знает», а не
    /// «сервер просит случайный». Проба одним таким отпечатком проваливается, и
    /// живой сервер получает «нет ответа» — ровно это и было видно на первом же
    /// прогоне: двенадцать серверов, все «нет ответа».
    /// </summary>
    public static async Task<int?> PingDelayAsync(Server server, string routeMode = RouteMode.Global,
        bool blockAds = false, double timeoutSeconds = 6.0, int portBase = 20000, CancellationToken ct = default)
    {
        var candidates = Candidates(server, "auto");
        if (candidates.Count > PingFpTries)
        {
            candidates = candidates.GetRange(0, PingFpTries);
        }

        // Транспорт без TLS отпечатком не отличается — хватит одной пробы.
        var needsFingerprint = server.Security == "reality" || server.Security == "tls";
        if (!needsFingerprint || candidates.Count <= 1)
        {
            return await XrayDelayAsync(server, routeMode, blockAds, timeoutSeconds, portBase, PingUrl, ct)
                .ConfigureAwait(false);
        }

        foreach (var fp in candidates)
        {
            var probe = server.Clone();
            probe.Fingerprint = fp;
            var ms = await XrayDelayAsync(probe, routeMode, blockAds, timeoutSeconds, portBase, PingUrl, ct)
                .ConfigureAwait(false);
            if (ms is not null)
            {
                return ms;
            }
        }
        return null;
    }

    /// <summary>
    /// Задержка запроса <b>через сам сервер</b>, в миллисекундах, или null.
    ///
    /// Отличие от <see cref="TcpPing"/> принципиальное. Тот меряет время
    /// установки TCP-соединения, то есть отвечает на вопрос «порт открыт», а не
    /// «сервер работает»: мёртвый VLESS на живом 443 показывался как честные
    /// 42 мс. Здесь поднимается временное ядро с конфигом этого сервера, и через
    /// него делается настоящий запрос — с рукопожатием протокола, TLS и всем,
    /// из-за чего сервер и может не работать.
    ///
    /// Плата известна: на каждый сервер уходит запуск xray и примерно полторы
    /// секунды на подъём портов. Поэтому замер списка идёт с ограничением по
    /// числу одновременных проб, а не веером.
    ///
    /// Отмена через <paramref name="ct"/> пробрасывается наружу
    /// OperationCanceledException — «замер отменили» и «сервер не ответил» это
    /// разные вещи, и вторым нельзя маскировать первое. Всё остальное (ядро не
    /// поднялось, прокси отказал, таймаут) возвращает null.
    /// </summary>
    public static async Task<int?> XrayDelayAsync(Server server, string routeMode, bool blockAds,
        double timeoutSeconds, int portBase, string url, CancellationToken ct)
    {
        // portBase разводит одновременные пробы по разным диапазонам портов.
        // Без него две пробы, запущенные разом, выбирают один и тот же свободный
        // порт: FreePort.Find закрывает сокет сразу после проверки, и вторая
        // проба видит его свободным. Ядро второй пробы не поднимается, а сервер
        // получает «нет ответа» — проверено живьём на списке из двенадцати
        // серверов.
        var socksPort = FreePort.Find(portBase);
        var httpPort = FreePort.Find(Math.Max(portBase + 1, socksPort + 1));

        JsonObject cfg;
        try
        {
            // logLevel=error: проба живёт секунды, и её болтовня в общий лог не нужна.
            cfg = XrayConfigBuilder.Build(server, socksPort, httpPort, routeMode, blockAds, logLevel: "error");
        }
        catch
        {
            return null;
        }

        var runner = new XrayRunner();
        try
        {
            runner.Start(cfg);
        }
        catch
        {
            runner.Dispose();
            return null;
        }

        try
        {
            await Task.Delay(TimeSpan.FromSeconds(1.3), ct).ConfigureAwait(false);   // дать ядру поднять порты

            // Ходим строго через HTTP-вход поднятого ядра. HttpClient создаётся
            // на пробу и тут же утилизируется: общий статический не годится —
            // у каждой пробы свой httpPort, а прокси задаётся на обработчике.
            var proxy = new WebProxy("http://127.0.0.1:" + httpPort.ToString(CultureInfo.InvariantCulture));
            var handler = new HttpClientHandler { Proxy = proxy, UseProxy = true };
            using var http = new HttpClient(handler, disposeHandler: true)
            {
                Timeout = TimeSpan.FromSeconds(timeoutSeconds),
            };

            // Время считаем вокруг запроса, а не вокруг всей пробы: подъём ядра —
            // плата за честность, к задержке до сервера отношения не имеет.
            var started = Stopwatch.StartNew();
            using var response = await http.GetAsync(url, ct).ConfigureAwait(false);
            var elapsed = started.ElapsedMilliseconds;
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }
            return (int)elapsed;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            // Свой таймаут HttpClient тоже кидает TaskCanceledException. Это не
            // отмена замера, а «сервер не ответил» — отдаём null, как Python.
            return null;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return null;
        }
        finally
        {
            runner.Stop();
            // Пауза без ct: она нужна, чтобы ОС успела отпустить порты до того,
            // как следующая проба их займёт. На отмене это нужно ровно так же.
            await Task.Delay(TimeSpan.FromSeconds(0.3)).ConfigureAwait(false);
            runner.Dispose();
        }
    }

    /// <summary>
    /// Запустить временное ядро с данным отпечатком и проверить выход в сеть.
    /// </summary>
    private static async Task<bool> ProbeAsync(Server server, string fp, string routeMode,
        bool blockAds, double timeoutSeconds, CancellationToken ct)
    {
        var probe = server.Clone();
        probe.Fingerprint = fp;
        var ms = await XrayDelayAsync(probe, routeMode, blockAds, timeoutSeconds, 20000, ProbeUrl, ct)
            .ConfigureAwait(false);
        return ms is not null;
    }
}
