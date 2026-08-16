using System.Text.Json.Nodes;

namespace SCVPN.Core;

/// <summary>
/// Режимы маршрутизации. Значения заморожены: они лежат в settings.json как
/// поле "route_mode" и переживают обновление приложения.
/// </summary>
public static class RouteMode
{
    /// <summary>Весь трафик через VPN, кроме локалки.</summary>
    public const string Global = "global";

    /// <summary>Российские сайты и IP напрямую, остальное в VPN.</summary>
    public const string BypassRu = "bypass_ru";
}

/// <summary>
/// Полный конфиг Xray из выбранного сервера.
///
/// Состоит из: <c>log</c> — куда писать логи ядра; <c>inbounds</c> — локальные
/// входы SOCKS и HTTP на 127.0.0.1, в них ходит системный прокси или TUN-движок;
/// <c>outbounds</c> — наш сервер (proxy), прямой выход (direct), чёрная дыра
/// (block); <c>routing</c> — что куда слать; <c>dns</c> — чем резолвим.
///
/// Готовый объект сериализуется в JSON и отдаётся ядру xray.exe.
/// </summary>
public static class XrayConfigBuilder
{
    // Локальные порты по умолчанию (слушают только 127.0.0.1, наружу не торчат).
    public const int DefaultSocksPort = 10808;
    public const int DefaultHttpPort = 10809;

    /// <summary>
    /// Собирает конфиг. Порядок ключей повторяет эталон, чтобы файл на диске
    /// глазами сравнивался с тем, что выдавала Python-версия.
    /// </summary>
    /// <remarks>
    /// Параметра «гео-базы отсутствуют» здесь нет намеренно, в отличие от
    /// macOS-ядра: на Windows geoip.dat и geosite.dat скачиваются вместе с
    /// xray.exe, так что ссылки вида <c>geosite:</c> всегда разрешимы.
    /// </remarks>
    public static JsonObject Build(
        Server server,
        int socksPort = DefaultSocksPort,
        int httpPort = DefaultHttpPort,
        string routeMode = RouteMode.Global,
        bool blockAds = false,
        string? logPath = null,
        string logLevel = "warning")
    {
        var log = new JsonObject { ["loglevel"] = logLevel };
        // Пустая строка — это «логировать некуда», а не «файл с пустым именем»:
        // Python отбрасывал её вместе с None, повторяем.
        if (!string.IsNullOrEmpty(logPath))
        {
            log["access"] = logPath;
            log["error"] = logPath;
        }

        return new JsonObject
        {
            ["log"] = log,
            ["inbounds"] = BuildInbounds(socksPort, httpPort),
            ["outbounds"] = new JsonArray
            {
                // proxy обязан быть первым: Xray берёт первый outbound как
                // умолчание для всего, что не попало ни в одно правило.
                server.ToOutbound("proxy"),
                new JsonObject
                {
                    ["tag"] = "direct",
                    ["protocol"] = "freedom",
                    ["settings"] = new JsonObject(),
                },
                new JsonObject
                {
                    ["tag"] = "block",
                    ["protocol"] = "blackhole",
                    ["settings"] = new JsonObject(),
                },
            },
            ["routing"] = BuildRouting(routeMode, blockAds),
            ["dns"] = BuildDns(routeMode),
        };
    }

    private static JsonArray BuildInbounds(int socksPort, int httpPort)
    {
        return new JsonArray
        {
            new JsonObject
            {
                ["tag"] = "socks-in",
                ["listen"] = "127.0.0.1",
                ["port"] = socksPort,
                ["protocol"] = "socks",
                ["settings"] = new JsonObject { ["udp"] = true, ["auth"] = "noauth" },
                ["sniffing"] = Sniffing(),
            },
            new JsonObject
            {
                ["tag"] = "http-in",
                ["listen"] = "127.0.0.1",
                ["port"] = httpPort,
                ["protocol"] = "http",
                ["settings"] = new JsonObject(),
                ["sniffing"] = Sniffing(),
            },
        };
    }

    // Python держал один словарь sniffing и клал его в оба инбаунда ссылкой.
    // JsonNode так нельзя: узел помнит родителя, и вторая вставка того же
    // экземпляра падает с InvalidOperationException. Поэтому фабрика.
    private static JsonObject Sniffing()
    {
        return new JsonObject
        {
            ["enabled"] = true,
            ["destOverride"] = new JsonArray { "http", "tls", "quic" },
        };
    }

    /// <summary>
    /// Правила маршрутизации.
    /// </summary>
    /// <remarks>
    /// Порядок значим: Xray берёт первое совпавшее правило, поэтому
    /// перестановка меняет поведение, а не оформление. Реклама в чёрную дыру →
    /// приватные адреса и домены напрямую → обход РФ → всё остальное в прокси.
    /// </remarks>
    private static JsonObject BuildRouting(string routeMode, bool blockAds)
    {
        var rules = new JsonArray();

        // 1) реклама в чёрную дыру (по желанию)
        if (blockAds)
        {
            rules.Add(new JsonObject
            {
                ["type"] = "field",
                ["outboundTag"] = "block",
                ["domain"] = new JsonArray { "geosite:category-ads-all" },
            });
        }

        // 2) локальная сеть и приватные адреса — всегда напрямую
        rules.Add(new JsonObject
        {
            ["type"] = "field",
            ["outboundTag"] = "direct",
            ["ip"] = new JsonArray { "geoip:private" },
        });
        rules.Add(new JsonObject
        {
            ["type"] = "field",
            ["outboundTag"] = "direct",
            ["domain"] = new JsonArray { "geosite:private" },
        });

        // 3) режим «обход РФ»: российские сайты и IP — напрямую
        if (routeMode == RouteMode.BypassRu)
        {
            rules.Add(new JsonObject
            {
                ["type"] = "field",
                ["outboundTag"] = "direct",
                ["domain"] = new JsonArray
                {
                    "geosite:category-ru", "geosite:yandex", "geosite:vk", "geosite:mailru",
                },
            });
            rules.Add(new JsonObject
            {
                ["type"] = "field",
                ["outboundTag"] = "direct",
                ["ip"] = new JsonArray { "geoip:ru" },
            });
        }

        // 4) всё остальное — в VPN. Явное правило не обязательно (умолчание —
        //    первый outbound, то есть proxy), но пусть будет видно.
        rules.Add(new JsonObject
        {
            ["type"] = "field",
            ["outboundTag"] = "proxy",
            ["network"] = "tcp,udp",
        });

        return new JsonObject
        {
            ["domainStrategy"] = "IPIfNonMatch",
            ["rules"] = rules,
        };
    }

    private static JsonObject BuildDns(string routeMode)
    {
        // DNS через прокси, чтобы провайдер не видел запросы и не было утечки.
        var servers = new JsonArray { "https://1.1.1.1/dns-query", "8.8.8.8" };

        if (routeMode == RouteMode.BypassRu)
        {
            // Российские домены резолвим через российский DNS напрямую — иначе
            // они уедут в туннель вместе с запросом и обход перестанет быть
            // обходом. Вставляем первым: Xray выбирает первый сервер, чей
            // список domains совпал.
            servers.Insert(0, new JsonObject
            {
                ["address"] = "77.88.8.8", // Yandex DNS
                ["domains"] = new JsonArray { "geosite:category-ru" },
            });
        }

        return new JsonObject
        {
            ["servers"] = servers,
            ["queryStrategy"] = "UseIP",
        };
    }
}
