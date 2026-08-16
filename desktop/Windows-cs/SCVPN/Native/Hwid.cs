using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace SCVPN.Native;

/// <summary>
/// Идентификатор устройства для панелей с привязкой к устройствам (HWID).
///
/// Зачем. Панели вроде Remnawave умеют ограничивать число устройств на аккаунт.
/// Клиент обязан представиться заголовком <c>x-hwid</c>, иначе подписка отдаёт
/// не серверы, а заглушку <c>vless://0000...@0.0.0.0:1#App not supported</c>.
/// Именно так и выглядела «странная строка App not supported» в списке серверов.
///
/// Что уходит на сервер. Не сам идентификатор машины, а его SHA-256 вместе с
/// солью приложения: провайдеру нужно лишь стабильное «это то же устройство»,
/// знать MachineGuid ему незачем. Плюс операционная система, её версия и модель —
/// их панель показывает в списке устройств, чтобы ты понимал, какое отключать.
///
/// Значение считается один раз и кладётся в settings.json. Дальше берётся
/// оттуда, даже если железо или Windows переустановлены: менять HWID нельзя,
/// иначе каждый раз занимался бы новый слот в лимите устройств.
/// </summary>
public static class Hwid
{
    /// <summary>
    /// Соль, чтобы наружу уходил не сам MachineGuid, а необратимая производная.
    ///
    /// Не менять ни соль, ни формат результата: значение уходит панели как
    /// <c>x-hwid</c>, и его смена означает новый слот в лимите устройств у
    /// каждого пользователя разом. Соль общая с macOS, iOS и Android, но
    /// исходник у каждой платформы свой — один человек с Мака и с ПК займёт
    /// два слота, и это верно, это разные устройства.
    /// </summary>
    public const string Salt = "scvpn-hwid-v1";

    private const string CryptographyKey = @"SOFTWARE\Microsoft\Cryptography";

    /// <summary>
    /// HWID из произвольного источника. Чистая функция — проверяется эталоном
    /// <c>SCVPN.Tests/Golden/hwid.json</c>, снятым с Python-версии.
    /// </summary>
    /// <remarks>
    /// Внешне это UUID, но настоящим UUID оно не является: ни версии, ни
    /// варианта в нужных битах нет — просто первые 32 знака шестнадцатеричного
    /// SHA-256, нарезанные на группы 8-4-4-4-12. Собрать «правильный» UUID
    /// через <see cref="Guid"/> значит выдать другое значение и обнулить
    /// привязку устройств у всех, кто уже пользуется приложением. Поэтому
    /// нарезка руками и байт в байт как в Python.
    /// </remarks>
    public static string Compute(string source)
    {
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(Salt + ":" + source));
        string hex = Convert.ToHexString(digest).ToLowerInvariant();
        return string.Concat(
            hex.Substring(0, 8), "-",
            hex.Substring(8, 4), "-",
            hex.Substring(12, 4), "-",
            hex.Substring(16, 4), "-",
            hex.Substring(20, 12));
    }

    /// <summary>Что-нибудь стабильное и уникальное для этой машины.</summary>
    public static string MachineSource()
    {
        try
        {
            // Registry64 обязателен: в 32-битном процессе на 64-битной Windows
            // чтение ушло бы в ветку WOW6432Node, где MachineGuid нет, и мы
            // молча свалились бы на запасной MAC — то есть выдали бы другой
            // HWID той же машине. В Python это KEY_WOW64_64KEY.
            using var hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var key = hklm.OpenSubKey(CryptographyKey, writable: false);
            if (key?.GetValue("MachineGuid") is string guid && guid.Length > 0)
                return guid;
        }
        catch (Exception ex) when (ex is IOException or System.Security.SecurityException or UnauthorizedAccessException)
        {
            // Ветки нет или её не дают читать — уходим на запасной вариант.
        }

        // Запасной вариант: MAC-адрес. Хуже (меняется с сетевой картой), но
        // лучше, чем случайное значение — оно бы пережило только текущую
        // установку. Формат "mac-%012x" заморожен: он уже посчитан у тех, у
        // кого MachineGuid не прочитался.
        return "mac-" + FirstMacHex();
    }

    private static string FirstMacHex()
    {
        try
        {
            NetworkInterface[] all = NetworkInterface.GetAllNetworkInterfaces();
            var candidates = all
                .Where(n => n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                            && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
                .Select(n => new { n.Id, Mac = n.GetPhysicalAddress().GetAddressBytes() })
                .Where(x => x.Mac.Length == 6 && x.Mac.Any(b => b != 0))
                // Состояние адаптера намеренно не смотрим: Wi-Fi, выключенный
                // в момент запуска, поменял бы HWID той же машины. И сортируем
                // по Id (GUID адаптера в реестре) — порядок перечисления от
                // запуска к запуску не гарантирован, а нам нужен один и тот же
                // ответ каждый раз.
                .OrderBy(x => x.Id, StringComparer.Ordinal)
                .ToList();
            if (candidates.Count > 0)
                return Convert.ToHexString(candidates[0].Mac).ToLowerInvariant();
        }
        catch (NetworkInformationException)
        {
            // Сетевой стек не отвечает — пусть будет нулевой адрес, как на macOS.
        }
        return "000000000000";
    }

    /// <summary>Стабильный HWID этого устройства. Считается один раз и запоминается.</summary>
    public static string DeviceId()
    {
        // settings.json читаем и пишем здесь напрямую, а не через Core.Store:
        // Native не имеет права зависеть от Core (зависимость идёт только в
        // обратную сторону). Работаем узлами JSON и трогаем один ключ "hwid",
        // поэтому остальные настройки переживают запись как есть.
        JsonObject root = ReadSettings();

        if (root["hwid"] is JsonValue value
            && value.TryGetValue(out string? saved)
            && !string.IsNullOrEmpty(saved))
        {
            return saved;
        }

        string hwid = Compute(MachineSource());
        root["hwid"] = JsonValue.Create(hwid);
        WriteSettings(root);
        return hwid;
    }

    /// <summary>Заголовки, которых ждут панели с учётом устройств.</summary>
    /// <remarks>
    /// Ровно четыре заголовка, ровно те же имена и источники, что в Python.
    /// Лишний заголовок — это изменение того, что видит панель, а панели по
    /// набору заголовков решают, отдавать ли серверы вообще.
    /// </remarks>
    public static Dictionary<string, string> DeviceHeaders()
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        headers["x-hwid"] = DeviceId();
        headers["x-device-os"] = "Windows";
        headers["x-ver-os"] = OsRelease();
        // platform.node() — сетевое имя машины; "PC", если его вдруг нет.
        string node = Environment.MachineName;
        headers["x-device-model"] = string.IsNullOrEmpty(node) ? "PC" : node;
        return headers;
    }

    /// <summary>
    /// Версия Windows для панели, с архитектурой в хвосте: «11 arm64».
    /// </summary>
    /// <remarks>
    /// Архитектуры в Python-версии не было, и в списке устройств панели
    /// ARM-ноутбук выглядел ровно как обычный x64. Заголовок показательный,
    /// на выдачу серверов не влияет — в отличие от x-hwid, который трогать
    /// нельзя.
    /// </remarks>
    private static string OsRelease()
    {
        Version v = Environment.OSVersion.Version;
        // Windows 11 представляется десяткой: отличить её можно только по
        // номеру сборки (первая 11-я сборка — 22000). Тот же трюк делает
        // platform.release() в свежем Python.
        string release = v.Major >= 10 && v.Build >= 22000 ? "11" : v.Major.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return release + " " + Arch.Host;
    }

    private static JsonObject ReadSettings()
    {
        try
        {
            if (File.Exists(Paths.SettingsFile))
            {
                string text = File.ReadAllText(Paths.SettingsFile, Encoding.UTF8);
                if (JsonNode.Parse(text) is JsonObject obj)
                    return obj;
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            // Файл битый или недоступен — начнём с пустого. Перезаписать его
            // не страшнее, чем не иметь HWID вообще.
        }
        return new JsonObject();
    }

    private static void WriteSettings(JsonObject root)
    {
        try
        {
            Paths.EnsureDirs();
            var options = new JsonSerializerOptions
            {
                WriteIndented = true,
                // Файл открывают текстовым редактором и читают глазами —
                // кириллица в нём должна остаться кириллицей (в Python это
                // ensure_ascii=False).
                Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            };
            File.WriteAllText(Paths.SettingsFile, root.ToJsonString(options), Encoding.UTF8);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Не записали — HWID пересчитается при следующем запуске и выйдет
            // тем же самым: он детерминирован от MachineGuid.
        }
    }
}
