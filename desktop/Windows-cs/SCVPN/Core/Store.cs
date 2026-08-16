using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using SCVPN.Native;

namespace SCVPN.Core;

// Хранение профилей и настроек в обычных JSON-файлах в папке данных.
// Файлы можно открыть любым текстовым редактором и проверить, что внутри, —
// никаких бинарных баз и скрытых полей. Отсюда два следствия, которые видны
// по всему файлу: формат на диске заморожен (имена ключей, порядок, отступ
// в два пробела, русский текст как есть), а любой мусор в файле обязан быть
// пережит без падения — пользователь имеет право поправить его руками.

/// <summary>Подписка: именованный URL и список серверов, полученных с него.</summary>
public sealed class Subscription
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("updated")] public string Updated { get; set; } = "";

    /// <summary>Когда подписку добавили в приложение.</summary>
    [JsonPropertyName("added")] public string Added { get; set; } = "";

    // Сведения от панели: срок, трафик, автообновление. Хранятся, чтобы экран
    // подписки открывался мгновенно и работал без сети — цифры от последнего
    // успешного обновления, дата этого обновления лежит в info.fetched.
    [JsonPropertyName("info")] public SubscriptionInfo Info { get; set; } = new();

    [JsonPropertyName("servers")] public List<Server> Servers { get; set; } = new();
}

/// <summary>Профили: подписки плюс одиночные серверы, добавленные ссылкой вручную.</summary>
public sealed class Profiles
{
    [JsonPropertyName("subscriptions")] public List<Subscription> Subscriptions { get; set; } = new();

    /// <summary>Одиночные серверы — те, что пользователь добавил ссылкой сам.</summary>
    [JsonPropertyName("servers")] public List<Server> Servers { get; set; } = new();

    // Порядок важен: одиночные идут первыми, за ними серверы подписок в порядке
    // самих подписок. По этому списку строится нумерация в интерфейсе.
    public List<Server> AllServers()
    {
        var result = new List<Server>(Servers);
        foreach (var sub in Subscriptions)
        {
            result.AddRange(sub.Servers);
        }
        return result;
    }
}

/// <summary>Настройки приложения. Значения по умолчанию — дословно из storage.py.</summary>
public sealed class Settings
{
    // Имена ключей вынесены в константы не для красоты: их читает не только
    // сериализатор, но и Store.ParseSettings, который разбирает файл вручную.
    // Два независимых списка имён разъехались бы при первой же правке.
    internal const string KeySocksPort = "socks_port";
    internal const string KeyHttpPort = "http_port";
    internal const string KeyRouteMode = "route_mode";
    internal const string KeyBlockAds = "block_ads";
    internal const string KeySystemProxy = "system_proxy";
    internal const string KeySelectedKey = "selected_key";
    internal const string KeyTlsFingerprint = "tls_fingerprint";
    internal const string KeyVpnMode = "vpn_mode";
    internal const string KeySplitMode = "split_mode";
    internal const string KeySplitApps = "split_apps";
    internal const string KeyTunStack = "tun_stack";
    internal const string KeyHwid = "hwid";

    internal static readonly HashSet<string> KnownKeys = new HashSet<string>(StringComparer.Ordinal)
    {
        KeySocksPort, KeyHttpPort, KeyRouteMode, KeyBlockAds, KeySystemProxy,
        KeySelectedKey, KeyTlsFingerprint, KeyVpnMode, KeySplitMode,
        KeySplitApps, KeyTunStack, KeyHwid,
    };

    // Порядок свойств = порядок ключей в файле: System.Text.Json пишет их в
    // порядке объявления, а эталонный settings.json снят с Python-версии.
    [JsonPropertyName(KeySocksPort)] public int SocksPort { get; set; } = 10808;
    [JsonPropertyName(KeyHttpPort)] public int HttpPort { get; set; } = 10809;

    // Литералы, а не RouteMode.Global / SplitMode.Off: одноимённое свойство
    // перекрывает имя статического класса внутри этого типа, и ссылка на
    // константу здесь не скомпилировалась бы.
    [JsonPropertyName(KeyRouteMode)] public string RouteMode { get; set; } = "global";   // global | bypass_ru
    [JsonPropertyName(KeyBlockAds)] public bool BlockAds { get; set; }

    /// <summary>Включать системный прокси при подключении (для режима proxy).</summary>
    [JsonPropertyName(KeySystemProxy)] public bool SystemProxy { get; set; } = true;

    /// <summary>Server.Key() выбранного сервера.</summary>
    [JsonPropertyName(KeySelectedKey)] public string SelectedKey { get; set; } = "";

    /// <summary>auto = автоподбор; либо chrome/firefox/safari/...</summary>
    [JsonPropertyName(KeyTlsFingerprint)] public string TlsFingerprint { get; set; } = "auto";

    /// <summary>proxy = системный прокси; tun = весь трафик (нужен админ).</summary>
    [JsonPropertyName(KeyVpnMode)] public string VpnMode { get; set; } = "proxy";

    /// <summary>off | exclude | include — раздельное туннелирование (только TUN).</summary>
    [JsonPropertyName(KeySplitMode)] public string SplitMode { get; set; } = "off";

    /// <summary>Имена .exe, к которым применяется SplitMode.</summary>
    [JsonPropertyName(KeySplitApps)] public List<string> SplitApps { get; set; } = new();

    // Сетевой стек sing-box в TUN. Настройка нужна только macOS, но обязана
    // пережить круг чтение-запись: один и тот же settings.json ездит между
    // сборками, и потеря ключа сбросила бы стек у пользователя на другой машине.
    [JsonPropertyName(KeyTunStack)] public string TunStack { get; set; } = "gvisor";

    // Пишется один раз навсегда: hwid — это привязка устройства в панели.
    // Пустая строка означает «ещё не выдан», читающая сторона обязана
    // трактовать её как отсутствие ключа, а не как валидный идентификатор.
    [JsonPropertyName(KeyHwid)] public string Hwid { get; set; } = "";

    // Ключи, о которых этот код не знает и знать не должен. Сохраняются
    // дословно: hwid когда-то был ровно таким неизвестным ключом, его писал
    // отдельный модуль. Структура с фиксированными полями потеряла бы его при
    // первом же сохранении, а пользователь занял бы новый слот в лимите
    // устройств панели. System.Text.Json пишет их последними — как в эталоне.
    [JsonExtensionData] public Dictionary<string, JsonElement> Unknown { get; set; } = new();
}

public static class Store
{
    // Формат записи повторяет Python: json.dumps(..., ensure_ascii=False, indent=2).
    // UnsafeRelaxedJsonEscaping обязателен — иначе русские имена серверов уедут
    // в \uXXXX. Разбор от этого не сломается, но файл перестанет читаться глазами,
    // а он для этого и заведён.
    private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    // Без BOM: те же файлы читает Python-версия при миграции, а json.loads
    // спотыкается о BOM в начале.
    private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    public static Profiles LoadProfiles()
    {
        var text = ReadTextOrNull(Paths.ProfilesFile, "профили");
        return text is null ? new Profiles() : ParseProfiles(text);
    }

    public static void SaveProfiles(Profiles profiles)
    {
        WriteAtomic(Paths.ProfilesFile, SerializeProfiles(profiles), "профили");
    }

    public static Settings LoadSettings()
    {
        var text = ReadTextOrNull(Paths.SettingsFile, "настройки");
        return text is null ? new Settings() : ParseSettings(text);
    }

    public static void SaveSettings(Settings settings)
    {
        WriteAtomic(Paths.SettingsFile, SerializeSettings(settings), "настройки");
    }

    /// <summary>Отметка времени в том же виде, что писал Python: <c>2026-08-15 17:42</c>.</summary>
    public static string NowIso()
    {
        // InvariantCulture не ради разделителей, а ради календаря: в ar-SA
        // ToString дал бы год по хиджре, и строка перестала бы сортироваться
        // рядом с уже записанными в файл.
        return DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
    }

    // ------------------------------------------------------------------
    // Чистые варианты: без диска, для тестов и для повторного использования
    // ------------------------------------------------------------------

    public static Profiles ParseProfiles(string json)
    {
        try
        {
            var profiles = JsonSerializer.Deserialize<Profiles>(json, JsonOptions);
            if (profiles is null)
            {
                return new Profiles();
            }
            Normalize(profiles);
            return profiles;
        }
        catch (Exception e)
        {
            // Ровно как Python: сообщение в stderr и пустые профили. Испорченный
            // файл не повод запирать приложение — из него ещё можно добавить
            // подписку заново.
            Console.Error.WriteLine($"[storage] не смог прочитать профили: {e.Message}");
            return new Profiles();
        }
    }

    public static string SerializeProfiles(Profiles profiles)
    {
        return JsonSerializer.Serialize(profiles, JsonOptions);
    }

    /// <summary>
    /// Разбор настроек. Читается вручную, ключ за ключом, а не одним
    /// Deserialize&lt;Settings&gt;: строгий разбор падает на первом же значении
    /// не того типа (пользователь правил файл руками и написал
    /// <c>"block_ads": "false"</c>), и тогда мы вернули бы умолчания, потеряв
    /// вместе с ними hwid. Python и Swift здесь работают со словарём и
    /// переживают такое без потерь — повторяем их поведение.
    /// </summary>
    public static Settings ParseSettings(string json)
    {
        var settings = new Settings();   // умолчания уже в инициализаторах свойств
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[storage] не смог прочитать настройки: {e.Message}");
            return settings;
        }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return settings;
            }

            settings.SocksPort = ReadInt(root, Settings.KeySocksPort, settings.SocksPort);
            settings.HttpPort = ReadInt(root, Settings.KeyHttpPort, settings.HttpPort);
            settings.RouteMode = ReadString(root, Settings.KeyRouteMode, settings.RouteMode);
            settings.BlockAds = ReadBool(root, Settings.KeyBlockAds, settings.BlockAds);
            settings.SystemProxy = ReadBool(root, Settings.KeySystemProxy, settings.SystemProxy);
            settings.SelectedKey = ReadString(root, Settings.KeySelectedKey, settings.SelectedKey);
            settings.TlsFingerprint = ReadString(root, Settings.KeyTlsFingerprint, settings.TlsFingerprint);
            settings.VpnMode = ReadString(root, Settings.KeyVpnMode, settings.VpnMode);
            settings.SplitMode = ReadString(root, Settings.KeySplitMode, settings.SplitMode);
            settings.SplitApps = ReadStringList(root, Settings.KeySplitApps, settings.SplitApps);
            settings.TunStack = ReadString(root, Settings.KeyTunStack, settings.TunStack);
            settings.Hwid = ReadString(root, Settings.KeyHwid, settings.Hwid);

            foreach (var property in root.EnumerateObject())
            {
                if (Settings.KnownKeys.Contains(property.Name))
                {
                    continue;
                }
                // Clone обязателен: JsonDocument владеет буфером и освобождает
                // его на выходе из using, а эти значения переживут метод.
                settings.Unknown[property.Name] = property.Value.Clone();
            }
        }

        return settings;
    }

    public static string SerializeSettings(Settings settings)
    {
        return JsonSerializer.Serialize(settings, JsonOptions);
    }

    // ------------------------------------------------------------------
    // Внутреннее
    // ------------------------------------------------------------------

    private static string? ReadTextOrNull(string path, string what)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }
            // Encoding.UTF8 здесь ещё и распознаёт BOM: файл, сохранённый
            // блокнотом, иначе не разобрался бы.
            return File.ReadAllText(path, Encoding.UTF8);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[storage] не смог прочитать {what}: {e.Message}");
            return null;
        }
    }

    /// <summary>
    /// Запись через временный файл рядом и переименование поверх. Python писал
    /// напрямую, и выключение питания в момент записи оставляло пустой
    /// settings.json — вместе с ним пропадали hwid и выбранный сервер.
    /// Временный файл обязан лежать в той же папке: переименование атомарно
    /// только внутри одного тома.
    /// </summary>
    private static void WriteAtomic(string path, string json, string what)
    {
        var tmp = path + ".tmp";
        try
        {
            Paths.EnsureDirs();
            File.WriteAllText(tmp, json, Utf8NoBom);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[storage] не смог записать {what}: {e.Message}");
            try
            {
                File.Delete(tmp);   // недописанный огрызок рядом с настоящим файлом никому не нужен
            }
            catch (Exception)
            {
                // Уже сообщили о главной беде; вторая жалоба подряд ничего не добавит.
            }
        }
    }

    // Файл мог быть правлен руками: null вместо списка разбирается без ошибки,
    // но уронил бы приложение позже и далеко отсюда.
    private static void Normalize(Profiles profiles)
    {
        if (profiles.Subscriptions is null)
        {
            profiles.Subscriptions = new List<Subscription>();
        }
        if (profiles.Servers is null)
        {
            profiles.Servers = new List<Server>();
        }
        foreach (var sub in profiles.Subscriptions)
        {
            if (sub.Servers is null)
            {
                sub.Servers = new List<Server>();
            }
            if (sub.Info is null)
            {
                sub.Info = new SubscriptionInfo();
            }
        }
    }

    // Значение не того типа = значения нет: возвращаем умолчание вместо
    // попытки привести. Приведение «10808.7 -> 10808» скрыло бы опечатку.
    private static string ReadString(JsonElement root, string key, string fallback)
    {
        if (root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String)
        {
            return value.GetString() ?? fallback;
        }
        return fallback;
    }

    private static int ReadInt(JsonElement root, string key, int fallback)
    {
        if (root.TryGetProperty(key, out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out var number))
        {
            return number;
        }
        return fallback;
    }

    private static bool ReadBool(JsonElement root, string key, bool fallback)
    {
        if (root.TryGetProperty(key, out var value)
            && (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False))
        {
            return value.GetBoolean();
        }
        return fallback;
    }

    // Не-строки молча отбрасываются — так же читает этот список интерфейс в Swift.
    private static List<string> ReadStringList(JsonElement root, string key, List<string> fallback)
    {
        if (!root.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Array)
        {
            return fallback;
        }
        var result = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                var s = item.GetString();
                if (s is not null)
                {
                    result.Add(s);
                }
            }
        }
        return result;
    }
}
