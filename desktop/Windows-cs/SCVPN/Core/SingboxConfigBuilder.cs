using System.Text.Json.Nodes;

namespace SCVPN.Core;

/// <summary>
/// Режимы раздельного туннелирования (split tunneling).
/// Строки заморожены: они лежат в settings.json как "split_mode".
/// </summary>
public static class SplitMode
{
    public const string Off = "off";          // все приложения через VPN
    public const string Exclude = "exclude";  // все через VPN, кроме выбранных
    public const string Include = "include";  // только выбранные через VPN
}

/// <summary>
/// Конфиг sing-box: TUN -&gt; SOCKS Xray, плюс правила раздельного туннеля.
///
/// Криптографии здесь нет вообще: TLS/Reality-рукопожатие с сервером делает
/// Xray, а sing-box лишь поднимает виртуальный адаптер (через wintun.dll),
/// забирает весь трафик системы и отдаёт его в локальный SOCKS Xray. Поэтому
/// автоподбор отпечатка одинаково работает и в режиме прокси, и в TUN.
///
/// Раздельное туннелирование делает сам sing-box: он умеет сопоставлять
/// соединение с процессом-владельцем (`process_name`) и отправлять его либо в
/// туннель, либо напрямую. Поэтому это работает только в TUN-режиме —
/// системный прокси про приложения ничего не знает.
///
/// Отличия от macOS-варианта (core-swift, SingboxConfig/Builder.swift):
///   - здесь есть `strict_route`: поле поддержано только Linux и Windows;
///   - здесь есть `interface_name`: на macOS utun-устройства именует ядро;
///   - `stack` не настраивается — на Windows он всегда gvisor (настройка
///     tun_stack из settings.json нужна только macOS, но обязана пережить
///     чтение-запись файла).
/// </summary>
public static class SingboxConfigBuilder
{
    /// <param name="xrayPath">
    /// Полный путь до xray.exe. Приходит снаружи (Native.Paths.XrayExe), чтобы
    /// конфиг можно было собрать в тесте, где никакого xray.exe нет.
    /// </param>
    public static JsonObject Build(
        int socksPort,
        IReadOnlyList<string> excludeIps,
        string xrayPath,
        string logLevel = "warn",
        string splitMode = SplitMode.Off,
        IReadOnlyList<string>? splitApps = null)
    {
        // Маска /32 без разбора версии адреса: сюда приходит результат
        // Tun.ResolveIps, а тот на Windows спрашивает только AF_INET.
        var excludes = new JsonArray();
        foreach (var ip in excludeIps)
        {
            excludes.Add(ip + "/32");
        }

        // Пустые и пробельные имена приложений отбрасываем: пользователь вводит
        // их руками, а sing-box на пустой строке в process_name падает при старте.
        var apps = new List<string>();
        if (splitApps != null)
        {
            foreach (var app in splitApps)
            {
                if (string.IsNullOrWhiteSpace(app))
                {
                    continue;
                }
                apps.Add(app.Trim());
            }
        }

        var rules = new JsonArray();

        // Первым делом выводим из туннеля сам Xray. Без этого режим «Авто» в TUN
        // зацикливался: Xray решает пустить российский сайт напрямую, его прямое
        // соединение снова попадает в TUN, оттуда обратно в Xray — и так по кругу.
        // Раньше это обходили запретом «Авто» в TUN-режиме, теперь запрет не нужен.
        // Правило переживает смену IP сервера, в отличие от route_exclude_address,
        // поэтому оно здесь главный пояс, а список исключений — запасной.
        var xrayPaths = new JsonArray();
        xrayPaths.Add(xrayPath);
        rules.Add(new JsonObject
        {
            ["process_path"] = xrayPaths,
            ["outbound"] = "direct",
        });

        // Пустой список приложений равносилен выключенному раздельному туннелю:
        // правило не добавляется, и final ниже остаётся "to-xray".
        if (apps.Count > 0 && splitMode == SplitMode.Exclude)
        {
            // Выбранные — мимо VPN, всё остальное (final) — в туннель.
            rules.Add(new JsonObject
            {
                ["process_name"] = ToArray(apps),
                ["outbound"] = "direct",
            });
        }
        else if (apps.Count > 0 && splitMode == SplitMode.Include)
        {
            // Выбранные — в туннель, всё остальное — напрямую (см. final ниже).
            rules.Add(new JsonObject
            {
                ["process_name"] = ToArray(apps),
                ["outbound"] = "to-xray",
            });
        }

        var final = (apps.Count > 0 && splitMode == SplitMode.Include) ? "direct" : "to-xray";

        var tunIn = new JsonObject
        {
            ["type"] = "tun",
            ["tag"] = "tun-in",
            ["interface_name"] = "SCVPNTun",
            ["address"] = new JsonArray { "172.18.0.1/30" },
            ["mtu"] = 1500,
            ["auto_route"] = true,
            ["strict_route"] = false,
            ["stack"] = "gvisor",
            // sing-box сам прописывает обходные маршруты на эти адреса и САМ ЖЕ
            // убирает их при выходе — чинить таблицу маршрутов руками не нужно.
            ["route_exclude_address"] = excludes,
        };

        var toXray = new JsonObject
        {
            ["type"] = "socks",
            ["tag"] = "to-xray",
            ["server"] = "127.0.0.1",
            ["server_port"] = socksPort,
            // Версия протокола — строка, а не число: так её ждёт схема sing-box.
            ["version"] = "5",
        };

        var direct = new JsonObject
        {
            ["type"] = "direct",
            ["tag"] = "direct",
        };

        var route = new JsonObject
        {
            ["auto_detect_interface"] = true,
            ["final"] = final,
            ["rules"] = rules,
        };

        return new JsonObject
        {
            ["log"] = new JsonObject { ["level"] = logLevel },
            ["inbounds"] = new JsonArray { tunIn },
            ["outbounds"] = new JsonArray { toXray, direct },
            ["route"] = route,
        };
    }

    /// <summary>
    /// Отдельный JsonArray на каждый вызов: один и тот же экземпляр JsonNode
    /// нельзя вставить в два документа, System.Text.Json бросит исключение.
    /// </summary>
    private static JsonArray ToArray(List<string> items)
    {
        var array = new JsonArray();
        foreach (var item in items)
        {
            array.Add(item);
        }
        return array;
    }
}
