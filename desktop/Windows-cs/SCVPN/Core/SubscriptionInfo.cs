using System.Globalization;
using System.Text.Json.Serialization;

namespace SCVPN.Core;

/// <summary>
/// Служебные сведения о подписке, которые панель шлёт в заголовках ответа.
///
/// Стандарт де-факто у панелей (Marzban, Remnawave, 3x-ui): рядом со списком
/// серверов в HTTP-заголовках едут срок действия, потраченный трафик, интервал
/// автообновления, ссылка на поддержку. Приложение их просто показывает — сами
/// цифры считает панель, мы ничего не додумываем.
///
/// Чего в заголовках нет — того и не показываем. Даты активации подписки там
/// не бывает, поэтому в интерфейсе стоит дата, когда подписку добавили в
/// приложение, и подписана она именно так.
/// </summary>
public sealed class SubscriptionInfo
{
    // Имена ключей заморожены форматом profiles.json на диске у пользователя —
    // менять их нельзя, иначе сведения о подписке потеряются при обновлении.
    [JsonPropertyName("title")] public string Title { get; set; } = "";        // profile-title
    [JsonPropertyName("account")] public string Account { get; set; } = "";    // имя файла из content-disposition, обычно логин
    [JsonPropertyName("upload")] public long Upload { get; set; }              // байт
    [JsonPropertyName("download")] public long Download { get; set; }          // байт
    [JsonPropertyName("total")] public long Total { get; set; }                // байт, 0 = безлимит
    [JsonPropertyName("expire")] public long Expire { get; set; }              // unix-время, 0 = бессрочно
    [JsonPropertyName("update_interval")] public int UpdateInterval { get; set; } // часы
    [JsonPropertyName("support_url")] public string SupportUrl { get; set; } = "";
    [JsonPropertyName("web_page_url")] public string WebPageUrl { get; set; } = "";
    [JsonPropertyName("announce")] public string Announce { get; set; } = "";
    [JsonPropertyName("hwid")] public Dictionary<string, string> Hwid { get; set; } = new();
    [JsonPropertyName("fetched")] public string Fetched { get; set; } = "";    // когда мы это прочитали

    // ---------- производные величины, чтобы интерфейс не считал сам ----------
    // Все они [JsonIgnore]: System.Text.Json пишет и get-only свойства, а в
    // profiles.json им делать нечего — они считаются из полей выше.

    [JsonIgnore] public long Used => Upload + Download;

    [JsonIgnore] public bool Unlimited => Total <= 0;

    /// <summary>Доля израсходованного лимита, 0…1. При безлимите — 0.</summary>
    [JsonIgnore] public double UsedRatio => Unlimited ? 0.0 : Math.Min(1.0, (double)Used / Total);

    [JsonIgnore] public DateTime? ExpiresAt =>
        Expire == 0 ? null : DateTimeOffset.FromUnixTimeSeconds(Expire).LocalDateTime;

    [JsonIgnore]
    public int? DaysLeft
    {
        get
        {
            DateTime? d = ExpiresAt;
            if (d is null) return null;
            // TimeSpan.Days отбрасывает дробную часть к нулю — так же считает
            // Swift (Calendar.dateComponents). Python здесь округлял вниз, и на
            // уже истёкшей подписке давал на день меньше; берём поведение Swift.
            return (d.Value - DateTime.Now).Days;
        }
    }

    [JsonIgnore]
    public bool DeviceLimitReached =>
        Hwid.TryGetValue("x-hwid-max-devices-reached", out string? v) && v == "true";

    /// <summary>Панели шлют название либо как есть, либо как <c>base64:…</c>.</summary>
    private static string MaybeBase64(string value)
    {
        if (!value.StartsWith("base64:", StringComparison.Ordinal)) return value;
        return Base64Url.TryDecodeText(value.Substring("base64:".Length)) ?? value;
    }

    /// <summary>Собрать сведения из заголовков ответа панели.</summary>
    public static SubscriptionInfo FromHeaders(IReadOnlyDictionary<string, string> headers)
    {
        // Заголовки регистронезависимы, а искать мы их будем по точным именам.
        Dictionary<string, string> h = new(StringComparer.Ordinal);
        foreach (KeyValuePair<string, string> kv in headers) h[kv.Key.ToLowerInvariant()] = kv.Value;

        SubscriptionInfo info = new()
        {
            // Формат фиксированный и инвариантный: строка уходит в profiles.json
            // и должна читаться одинаково при любой локали системы.
            Fetched = DateTime.Now.ToString("dd.MM.yyyy HH:mm", CultureInfo.InvariantCulture),
        };

        info.Title = MaybeBase64(Get(h, "profile-title"));
        info.Announce = MaybeBase64(Get(h, "announce"));
        info.SupportUrl = Get(h, "support-url");
        info.WebPageUrl = Get(h, "profile-web-page-url");

        // content-disposition: attachment; filename=F_Semin_key-1
        string disp = Get(h, "content-disposition");
        int at = disp.IndexOf("filename=", StringComparison.Ordinal);
        if (at >= 0)
            info.Account = disp.Substring(at + "filename=".Length).Trim().Trim('"', ';', ' ');

        // subscription-userinfo: upload=0; download=123; total=0; expire=1788405825
        foreach (string part in Get(h, "subscription-userinfo").Split(';'))
        {
            string piece = part.Trim();
            int eq = piece.IndexOf('=');
            if (eq < 0) continue;
            string key = piece.Substring(0, eq);
            // Через double: панели присылают и `0`, и `0.0`, и второе на строгом
            // разборе целого потеряло бы значение молча.
            if (!double.TryParse(piece.Substring(eq + 1), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out double raw)) continue;
            // NaN/бесконечность/заведомо не влезающее в long: приведение к long
            // таких значений в C# не определено, а дальше это уходит в
            // DateTimeOffset и уронило бы окно. Панель такого не шлёт — но шлёт
            // не только панель.
            if (!double.IsFinite(raw) || Math.Abs(raw) >= 9.2e18) continue;
            long value = (long)raw;
            switch (key)
            {
                case "upload": info.Upload = value; break;
                case "download": info.Download = value; break;
                case "total": info.Total = value; break;
                case "expire": info.Expire = value; break;
            }
        }

        // Интервал — только целое: "12.0" здесь не принимает ни Python, ни Swift.
        info.UpdateInterval = int.TryParse(Get(h, "profile-update-interval"), NumberStyles.Integer,
            CultureInfo.InvariantCulture, out int hours) ? hours : 0;

        foreach (KeyValuePair<string, string> kv in h)
            if (kv.Key.StartsWith("x-hwid", StringComparison.Ordinal))
                info.Hwid[kv.Key] = kv.Value;

        return info;
    }

    private static string Get(Dictionary<string, string> h, string key) =>
        h.TryGetValue(key, out string? v) ? v : "";

    // ----------------------------------------------------------------------
    // Человеческие подписи — одни и те же во всех местах интерфейса
    // ----------------------------------------------------------------------

    private static readonly (string Unit, long Size)[] SizeUnits =
    {
        ("ТБ", 1L << 40), ("ГБ", 1L << 30), ("МБ", 1L << 20), ("КБ", 1L << 10),
    };

    public static string HumanBytes(long n)
    {
        if (n <= 0) return "0 Б";
        foreach ((string unit, long size) in SizeUnits)
        {
            if (n < size) continue;
            // Math.Round(…, ToEven) — не украшение: ToString("F2") в .NET округляет
            // ровную середину от нуля (1.125 → "1.13"), а Python и Swift — к
            // чётному (→ "1.12"). Деление на степень двойки такие середины даёт
            // регулярно, и подписи разъехались бы между платформами.
            double v = Math.Round((double)n / size, 2, MidpointRounding.ToEven);
            return v.ToString("F2", CultureInfo.InvariantCulture) + " " + unit;
        }
        return n.ToString(CultureInfo.InvariantCulture) + " Б";
    }

    /// <summary>Интервал автообновления. Панели шлют его в часах.</summary>
    public static string HumanInterval(int hours)
    {
        if (hours <= 0) return "не задано";
        if (hours % 24 == 0)
        {
            int days = hours / 24;
            return days > 1
                ? "раз в " + days.ToString(CultureInfo.InvariantCulture) + " дн."
                : "раз в сутки";
        }
        return "раз в " + hours.ToString(CultureInfo.InvariantCulture) + " ч.";
    }
}
