using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace SCVPN.Core;

/// <summary>
/// Разбор ссылок vless://, vmess://, trojan://, ss:// и содержимого подписки.
/// </summary>
public static class LinkParser
{
    // Разделители строк подписки. Берём весь набор Unicode-переводов строки, а не
    // только \n и \r: панели встречаются с U+2028 внутри JSON-ответа.
    private static readonly char[] NewlineChars =
    {
        '\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'
    };

    /// <summary>
    /// Разобрать одну ссылку в <see cref="Server"/>. <c>null</c> — формат не распознан.
    /// </summary>
    /// <remarks>
    /// Не бросает намеренно: подписка — это сотня строк, и одна кривая среди них не
    /// должна стоить пользователю всех остальных.
    /// </remarks>
    public static Server? ParseLink(string link)
    {
        link = (link ?? string.Empty).Trim();
        if (link.Length == 0) return null;
        if (link.StartsWith("vless://", StringComparison.Ordinal)) return ParseVless(link);
        if (link.StartsWith("vmess://", StringComparison.Ordinal)) return ParseVmess(link);
        if (link.StartsWith("trojan://", StringComparison.Ordinal)) return ParseTrojan(link);
        if (link.StartsWith("ss://", StringComparison.Ordinal)) return ParseShadowsocks(link);
        return null;
    }

    /// <summary>
    /// Разобрать содержимое подписки в список серверов.
    /// </summary>
    /// <remarks>
    /// Подписка часто приходит как base64 от списка ссылок. Пробуем оба варианта и
    /// берём тот, что дал больше серверов: угадывать по виду текста ненадёжно,
    /// а лишний разбор стоит микросекунды.
    /// </remarks>
    public static List<Server> ParseSubscriptionText(string text)
    {
        text = (text ?? string.Empty).Trim();

        var candidates = new List<string>();
        candidates.Add(text);
        string? decoded = Base64Url.TryDecodeText(text);
        if (decoded != null) candidates.Add(decoded);

        var best = new List<Server>();
        foreach (string candidate in candidates)
        {
            var servers = new List<Server>();
            foreach (string line in candidate.Split(NewlineChars, StringSplitOptions.RemoveEmptyEntries))
            {
                Server? s = ParseLink(line);
                if (s != null) servers.Add(s);
            }
            if (servers.Count > best.Count) best = servers;
        }
        return best;
    }

    // ------------------------------------------------------------------
    // Разбиение ссылки
    // ------------------------------------------------------------------

    /// <summary>
    /// Разбор <c>схема://userinfo@host:port?query#fragment</c> без <c>Uri</c>.
    /// </summary>
    /// <remarks>
    /// Штатный разбор URI спотыкается о то, что живьём встречается сплошь и рядом:
    /// не-ASCII в <c>#fragment</c> (имя сервера по-русски), <c>:</c> и <c>/</c>
    /// внутри пароля trojan. Своё разбиение по разделителям устойчивее и понятнее.
    /// </remarks>
    private sealed class LinkParts
    {
        public string UserInfo = string.Empty;
        public string Host = string.Empty;
        public int? Port;
        public Dictionary<string, string> Query = new();
        public string Fragment = string.Empty;
    }

    private static LinkParts SplitLink(string link, string scheme)
    {
        string rest = link.Substring(scheme.Length);
        var parts = new LinkParts();

        // Порядок важен: сначала '#', потом '?'. Иначе '?' внутри имени сервера
        // (а он там бывает) откусил бы половину ссылки в query.
        int hash = rest.IndexOf('#');
        if (hash >= 0)
        {
            parts.Fragment = Unescape(rest.Substring(hash + 1));
            rest = rest.Substring(0, hash);
        }
        int q = rest.IndexOf('?');
        if (q >= 0)
        {
            parts.Query = QueryPairs(rest.Substring(q + 1));
            rest = rest.Substring(0, q);
        }
        // Поиск '@' с конца: пароль trojan вполне может содержать '@'.
        int at = rest.LastIndexOf('@');
        if (at >= 0)
        {
            parts.UserInfo = Unescape(rest.Substring(0, at));
            rest = rest.Substring(at + 1);
        }
        // Хост в квадратных скобках — IPv6-литерал.
        int close = rest.IndexOf(']');
        if (rest.StartsWith("[", StringComparison.Ordinal) && close >= 0)
        {
            parts.Host = rest.Substring(1, close - 1);
            string after = rest.Substring(close + 1);
            if (after.StartsWith(":", StringComparison.Ordinal)) parts.Port = ParsePort(after.Substring(1));
        }
        else
        {
            int colon = rest.LastIndexOf(':');
            if (colon >= 0)
            {
                parts.Host = rest.Substring(0, colon);
                // Порт может не разобраться — тогда его просто нет, а хост остаётся.
                parts.Port = ParsePort(rest.Substring(colon + 1));
            }
            else
            {
                parts.Host = rest;
            }
        }
        return parts;
    }

    /// <summary>
    /// Параметры запроса, раскодированные <b>ровно один раз</b>.
    /// </summary>
    /// <remarks>
    /// Python здесь опирался на <c>parse_qs</c>, который декодирует сам, и поверх
    /// него звал <c>unquote</c> ещё раз для <c>path</c>, <c>alpn</c> и
    /// <c>serviceName</c> — то есть декодировал дважды. На живых ссылках это
    /// незаметно (после первого прохода процентов не остаётся), но
    /// <c>path=%252F</c> приехал бы в конфиг как <c>/</c> вместо <c>%2F</c>.
    /// Повторять этот баг незачем: декодируем один раз, все поля одинаково.
    ///
    /// <c>+</c> в пробел не превращаем, в отличие от <c>parse_qs</c>: в значениях
    /// вроде <c>pbk</c> лежит base64, и такая замена испортила бы ключ.
    /// </remarks>
    private static Dictionary<string, string> QueryPairs(string query)
    {
        var outMap = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string pair in query.Split(new[] { '&' }, StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = pair.IndexOf('=');
            if (eq < 0)
            {
                if (!outMap.ContainsKey(pair)) outMap[pair] = string.Empty;
                continue;
            }
            string key = pair.Substring(0, eq);
            string value = Unescape(pair.Substring(eq + 1));
            // Первое вхождение выигрывает — так же ведёт себя parse_qs + [0].
            if (!outMap.ContainsKey(key)) outMap[key] = value;
        }
        return outMap;
    }

    private static string Unescape(string s)
    {
        try
        {
            return Uri.UnescapeDataString(s);
        }
        catch (UriFormatException)
        {
            // Битая процентная последовательность — отдаём как есть, ровно как
            // Swift с его `removingPercentEncoding ?? s`.
            return s;
        }
    }

    private static int? ParsePort(string s)
    {
        return int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out int n) ? n : null;
    }

    /// <summary>Значение параметра; отсутствующий — <paramref name="fallback"/>.</summary>
    /// <remarks>
    /// Пустое значение (<c>sid=</c>) — это именно пустая строка, а не отсутствие
    /// параметра: <c>parse_qs</c> в Python такие выбрасывал, мы их сохраняем.
    /// </remarks>
    private static string Get(Dictionary<string, string> q, string key, string fallback = "")
    {
        return q.TryGetValue(key, out string? v) && v is not null ? v : fallback;
    }

    private static Dictionary<string, JsonElement> Extra(Dictionary<string, string> query)
    {
        var outMap = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var kv in query) outMap[kv.Key] = JsonSerializer.SerializeToElement(kv.Value);
        return outMap;
    }

    // ------------------------------------------------------------------
    // Отдельные протоколы
    // ------------------------------------------------------------------

    private static Server? ParseVless(string link)
    {
        // vless://uuid@host:port?params#name
        LinkParts p = SplitLink(link, "vless://");
        // Пустой хост или пустой uuid — не сервер. Python возвращал тут объект с
        // пустым адресом, и он попадал в список как строка, к которой нельзя
        // подключиться.
        if (p.Host.Length == 0 || p.UserInfo.Length == 0) return null;

        var s = new Server();
        s.Protocol = "vless";
        s.Uuid = p.UserInfo;
        s.Address = p.Host;
        s.Port = p.Port ?? 443;
        s.Name = p.Fragment;
        s.Network = Get(p.Query, "type", "tcp");
        s.Security = Get(p.Query, "security", "none");
        s.Flow = Get(p.Query, "flow");
        // peer — устаревшее имя того же поля; берём его, только если sni пуст.
        s.Sni = Get(p.Query, "sni");
        if (s.Sni.Length == 0) s.Sni = Get(p.Query, "peer");
        s.Fingerprint = Get(p.Query, "fp");
        s.Alpn = Get(p.Query, "alpn");
        s.PublicKey = Get(p.Query, "pbk");
        s.ShortId = Get(p.Query, "sid");
        s.SpiderX = Get(p.Query, "spx", "/");
        s.WsPath = Get(p.Query, "path", "/");
        s.WsHost = Get(p.Query, "host");
        s.GrpcService = Get(p.Query, "serviceName");
        s.AllowInsecure = Get(p.Query, "allowInsecure") is "1" or "true";
        s.Extra = Extra(p.Query);
        return s;
    }

    private static Server? ParseTrojan(string link)
    {
        // trojan://password@host:port?params#name
        LinkParts p = SplitLink(link, "trojan://");
        if (p.Host.Length == 0 || p.UserInfo.Length == 0) return null;

        var s = new Server();
        s.Protocol = "trojan";
        s.Password = p.UserInfo;
        s.Address = p.Host;
        s.Port = p.Port ?? 443;
        s.Name = p.Fragment;
        s.Network = Get(p.Query, "type", "tcp");
        // У trojan умолчание security — tls, а не none: без TLS он не работает.
        s.Security = Get(p.Query, "security", "tls");
        s.Sni = Get(p.Query, "sni");
        if (s.Sni.Length == 0) s.Sni = Get(p.Query, "peer");
        s.Fingerprint = Get(p.Query, "fp");
        s.Alpn = Get(p.Query, "alpn");
        s.WsPath = Get(p.Query, "path", "/");
        s.WsHost = Get(p.Query, "host");
        s.GrpcService = Get(p.Query, "serviceName");
        s.AllowInsecure = Get(p.Query, "allowInsecure") is "1" or "true";
        s.Extra = Extra(p.Query);
        return s;
    }

    private static Server? ParseVmess(string link)
    {
        // vmess://base64(json)
        string raw = link.Substring("vmess://".Length);
        string? text = Base64Url.TryDecodeText(raw);
        if (text == null) return null;

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }

        using (doc)
        {
            JsonElement cfg = doc.RootElement;
            if (cfg.ValueKind != JsonValueKind.Object) return null;

            var s = new Server();
            s.Protocol = "vmess";
            s.Name = VmessStr(cfg, "ps");
            s.Address = VmessStr(cfg, "add");
            s.Port = VmessInt(cfg, "port", 443);
            s.Uuid = VmessStr(cfg, "id");
            s.AlterId = VmessInt(cfg, "aid", 0);
            string net = VmessStr(cfg, "net");
            s.Network = net.Length == 0 ? "tcp" : net;
            string tls = VmessStr(cfg, "tls");
            s.Security = tls.Length == 0 ? "none" : tls;
            string sni = VmessStr(cfg, "sni");
            s.Sni = sni.Length == 0 ? VmessStr(cfg, "host") : sni;
            s.Fingerprint = VmessStr(cfg, "fp");
            s.Alpn = VmessStr(cfg, "alpn");
            string path = VmessStr(cfg, "path");
            s.WsPath = path.Length == 0 ? "/" : path;
            s.WsHost = VmessStr(cfg, "host");
            // У grpc панели кладут имя сервиса в то же поле path.
            s.GrpcService = s.Network == "grpc" ? VmessStr(cfg, "path") : string.Empty;

            // В extra переносим только строки и числа: сложные значения в модели
            // всё равно негде хранить, а Clone нужен потому, что JsonDocument
            // умрёт вместе с этим using.
            var extra = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (JsonProperty prop in cfg.EnumerateObject())
            {
                if (prop.Value.ValueKind is JsonValueKind.String or JsonValueKind.Number)
                    extra[prop.Name] = prop.Value.Clone();
            }
            s.Extra = extra;

            if (s.Address.Length == 0) return null;
            return s;
        }
    }

    /// <remarks>
    /// Панели одинаково охотно шлют и <c>"port": 443</c>, и <c>"port": "443"</c>,
    /// поэтому число молча приводится к строке, а не считается чужим типом.
    /// </remarks>
    private static string VmessStr(JsonElement cfg, string key)
    {
        if (!cfg.TryGetProperty(key, out JsonElement v)) return string.Empty;
        if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
        if (v.ValueKind == JsonValueKind.Number) return v.GetRawText();
        return string.Empty;
    }

    private static int VmessInt(JsonElement cfg, string key, int fallback)
    {
        if (!cfg.TryGetProperty(key, out JsonElement v)) return fallback;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out int n)) return n;
        if (v.ValueKind == JsonValueKind.String &&
            int.TryParse(v.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int m)) return m;
        return fallback;
    }

    private static Server? ParseShadowsocks(string link)
    {
        // Возможные формы:
        //   ss://base64(method:password)@host:port#name
        //   ss://base64(method:password@host:port)#name
        var s = new Server();
        s.Protocol = "shadowsocks";
        string body = link.Substring("ss://".Length);

        int hash = body.IndexOf('#');
        if (hash >= 0)
        {
            s.Name = Unescape(body.Substring(hash + 1));
            body = body.Substring(0, hash);
        }
        // Параметры запроса у ss встречаются (plugin=…), но в модели им места нет —
        // отбрасываем, как это делал Python.
        int q = body.IndexOf('?');
        if (q >= 0) body = body.Substring(0, q);

        string methodPass;
        string hostPart;
        int at = body.LastIndexOf('@');
        if (at >= 0)
        {
            string userInfo = body.Substring(0, at);
            // userinfo бывает и base64, и открытым method:password. Python здесь
            // ошибался: base64.b64decode молча выбрасывает символы вне алфавита
            // (':' и '%'), поэтому «расшифровывал» открытый текст в мусор. Наш
            // декодер такой вход отвергает, и мы честно откатываемся на текст.
            methodPass = Base64Url.TryDecodeText(userInfo) ?? Unescape(userInfo);
            hostPart = body.Substring(at + 1);
        }
        else
        {
            string? decoded = Base64Url.TryDecodeText(body);
            if (decoded == null) return null;
            int dat = decoded.LastIndexOf('@');
            if (dat < 0) return null;
            methodPass = decoded.Substring(0, dat);
            hostPart = decoded.Substring(dat + 1);
        }

        // Пароль может содержать ':', поэтому режем по первому вхождению.
        int colon = methodPass.IndexOf(':');
        if (colon < 0) return null;
        s.Method = methodPass.Substring(0, colon);
        s.Password = methodPass.Substring(colon + 1);

        int hostColon = hostPart.LastIndexOf(':');
        if (hostColon >= 0)
        {
            s.Address = hostPart.Substring(0, hostColon);
            s.Port = ParsePort(hostPart.Substring(hostColon + 1)) ?? 8388;
        }
        else
        {
            s.Address = hostPart;
            s.Port = 8388;
        }

        if (s.Address.Length == 0 || s.Method.Length == 0) return null;
        return s;
    }
}
