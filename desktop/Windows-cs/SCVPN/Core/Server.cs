using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace SCVPN.Core;

/// <summary>
/// Один VPN-сервер: уже разобранные поля ссылки (vless:// и т.п.).
///
/// Имена ключей на диске заморожены — это содержимое profiles.json у
/// пользователя. Поэтому [JsonPropertyName] стоит на каждом поле, где имя
/// свойства и имя ключа расходятся: правка любого имени молча потеряла бы
/// поле при следующем чтении.
///
/// Порядок свойств тоже значим: System.Text.Json пишет их в порядке
/// объявления, а эталонный profiles.json снят с Python, где поля шли ровно
/// так же (см. desktop/Windows/models.py).
/// </summary>
public sealed class Server
{
    // --- основное ---
    [JsonPropertyName("protocol")]
    public string Protocol { get; set; } = "vless";     // vless | vmess | trojan | shadowsocks

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";              // отображаемое имя (из #fragment)

    [JsonPropertyName("address")]
    public string Address { get; set; } = "";           // хост или IP

    [JsonPropertyName("port")]
    public int Port { get; set; } = 443;

    // --- учётные данные ---
    [JsonPropertyName("uuid")]
    public string Uuid { get; set; } = "";              // id для vless/vmess

    [JsonPropertyName("password")]
    public string Password { get; set; } = "";          // пароль для trojan

    [JsonPropertyName("method")]
    public string Method { get; set; } = "";            // шифр для shadowsocks

    [JsonPropertyName("alter_id")]
    public int AlterId { get; set; }                    // vmess alterId (обычно 0)

    // --- транспорт (streamSettings) ---
    [JsonPropertyName("network")]
    public string Network { get; set; } = "tcp";        // tcp | ws | grpc | http | quic | kcp

    [JsonPropertyName("security")]
    public string Security { get; set; } = "none";      // none | tls | reality

    [JsonPropertyName("flow")]
    public string Flow { get; set; } = "";              // xtls-rprx-vision и т.п. (vless)

    // TLS / Reality
    [JsonPropertyName("sni")]
    public string Sni { get; set; } = "";               // serverName

    [JsonPropertyName("fingerprint")]
    public string Fingerprint { get; set; } = "";       // uTLS fingerprint (chrome/firefox/…)

    [JsonPropertyName("alpn")]
    public string Alpn { get; set; } = "";              // h2,http/1.1

    [JsonPropertyName("public_key")]
    public string PublicKey { get; set; } = "";         // Reality pbk

    [JsonPropertyName("short_id")]
    public string ShortId { get; set; } = "";           // Reality sid

    [JsonPropertyName("spider_x")]
    public string SpiderX { get; set; } = "/";          // Reality spx

    [JsonPropertyName("allow_insecure")]
    public bool AllowInsecure { get; set; }             // пропускать ошибки сертификата (TLS)

    // параметры путей транспорта
    [JsonPropertyName("ws_path")]
    public string WsPath { get; set; } = "/";           // путь для ws / http

    [JsonPropertyName("ws_host")]
    public string WsHost { get; set; } = "";            // Host-заголовок для ws

    [JsonPropertyName("grpc_service")]
    public string GrpcService { get; set; } = "";       // serviceName для grpc

    /// <summary>
    /// Сырые параметры ссылки на всякий случай — и чтобы неизвестные ключи
    /// переживали круг чтение-запись.
    /// </summary>
    [JsonPropertyName("extra")]
    public Dictionary<string, JsonElement> Extra { get; set; } = new();

    [JsonIgnore]
    public string Title => Name.Length > 0
        ? Name
        // Инвариантная культура: порт склеивается в текст, который видит
        // пользователь и с которым сравниваются эталоны.
        : Address + ":" + Port.ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// Грубый ключ для отсева дубликатов при обновлении подписки.
    ///
    /// Формат заморожен: он лежит в settings.json как selected_key, и смена
    /// формата потеряла бы выбранный сервер у каждого пользователя.
    /// </summary>
    public string Key()
    {
        var secret = Uuid.Length == 0 ? Password : Uuid;
        return string.Format(
            CultureInfo.InvariantCulture,
            "{0}://{1}@{2}:{3}/{4}/{5}",
            Protocol, secret, Address, Port, Network, Security);
    }

    // ------------------------------------------------------------------
    // Сборка outbound для Xray
    // ------------------------------------------------------------------
    public JsonObject ToOutbound(string tag = "proxy")
    {
        var outbound = new JsonObject
        {
            ["tag"] = tag,
            ["protocol"] = Protocol,
        };

        switch (Protocol)
        {
            case "vless":
            {
                var user = new JsonObject
                {
                    ["id"] = Uuid,
                    ["encryption"] = "none",
                };
                // flow добавляется только непустым: Xray отвергает конфиг, где
                // flow есть, но пустой.
                if (Flow.Length > 0)
                    user["flow"] = Flow;
                outbound["settings"] = new JsonObject
                {
                    ["vnext"] = new JsonArray(new JsonObject
                    {
                        ["address"] = Address,
                        ["port"] = Port,
                        ["users"] = new JsonArray(user),
                    }),
                };
                break;
            }
            case "vmess":
            {
                var user = new JsonObject
                {
                    ["id"] = Uuid,
                    ["alterId"] = AlterId,
                    ["security"] = "auto",
                };
                outbound["settings"] = new JsonObject
                {
                    ["vnext"] = new JsonArray(new JsonObject
                    {
                        ["address"] = Address,
                        ["port"] = Port,
                        ["users"] = new JsonArray(user),
                    }),
                };
                break;
            }
            case "trojan":
                outbound["settings"] = new JsonObject
                {
                    ["servers"] = new JsonArray(new JsonObject
                    {
                        ["address"] = Address,
                        ["port"] = Port,
                        ["password"] = Password,
                    }),
                };
                break;
            case "shadowsocks":
                outbound["settings"] = new JsonObject
                {
                    ["servers"] = new JsonArray(new JsonObject
                    {
                        ["address"] = Address,
                        ["port"] = Port,
                        ["method"] = Method,
                        ["password"] = Password,
                    }),
                };
                break;
            default:
                throw new InvalidOperationException($"Неизвестный протокол: {Protocol}");
        }

        outbound["streamSettings"] = StreamSettings();
        return outbound;
    }

    private JsonObject StreamSettings()
    {
        var ss = new JsonObject { ["network"] = Network };

        // --- безопасность транспорта ---
        switch (Security)
        {
            case "reality":
                ss["security"] = "reality";
                ss["realitySettings"] = new JsonObject
                {
                    ["serverName"] = Sni,
                    // Пустой отпечаток означает «панель его не прислала», а не
                    // «отпечаток не нужен»: Reality без uTLS не работает.
                    ["fingerprint"] = Fingerprint.Length > 0 ? Fingerprint : "chrome",
                    ["publicKey"] = PublicKey,
                    ["shortId"] = ShortId,
                    ["spiderX"] = SpiderX.Length > 0 ? SpiderX : "/",
                };
                break;
            case "tls":
            {
                ss["security"] = "tls";
                var tls = new JsonObject
                {
                    // Без sni сертификат проверяется по адресу подключения —
                    // так же ведёт себя браузер.
                    ["serverName"] = Sni.Length > 0 ? Sni : Address,
                    ["allowInsecure"] = AllowInsecure,
                };
                if (Fingerprint.Length > 0)
                    tls["fingerprint"] = Fingerprint;
                var alpns = new JsonArray();
                foreach (var part in Alpn.Split(','))
                {
                    var item = part.Trim();
                    if (item.Length > 0)
                        alpns.Add(item);
                }
                if (alpns.Count > 0)
                    tls["alpn"] = alpns;
                ss["tlsSettings"] = tls;
                break;
            }
            default:
                ss["security"] = "none";
                break;
        }

        // --- настройки конкретного транспорта ---
        switch (Network)
        {
            case "ws":
            {
                var ws = new JsonObject { ["path"] = WsPath.Length > 0 ? WsPath : "/" };
                // Отдельного host у ссылки может не быть — тогда Host берётся
                // из sni, иначе CDN не найдёт нужный бэкенд.
                var host = WsHost.Length > 0 ? WsHost : Sni;
                if (host.Length > 0)
                    ws["headers"] = new JsonObject { ["Host"] = host };
                ss["wsSettings"] = ws;
                break;
            }
            case "grpc":
                ss["grpcSettings"] = new JsonObject { ["serviceName"] = GrpcService };
                break;
            case "http":    // h2
            {
                var h = new JsonObject { ["path"] = WsPath.Length > 0 ? WsPath : "/" };
                if (WsHost.Length > 0)
                    h["host"] = new JsonArray(WsHost);
                ss["httpSettings"] = h;
                break;
            }
            // tcp и прочее — без доп. настроек
        }

        return ss;
    }

    /// <summary>
    /// Глубокая копия. Нужна подбору отпечатка: он перебирает fingerprint на
    /// копии сервера, и правка не должна доставать до профиля в списке.
    /// </summary>
    public Server Clone()
    {
        var copy = new Server
        {
            Protocol = Protocol,
            Name = Name,
            Address = Address,
            Port = Port,
            Uuid = Uuid,
            Password = Password,
            Method = Method,
            AlterId = AlterId,
            Network = Network,
            Security = Security,
            Flow = Flow,
            Sni = Sni,
            Fingerprint = Fingerprint,
            Alpn = Alpn,
            PublicKey = PublicKey,
            ShortId = ShortId,
            SpiderX = SpiderX,
            AllowInsecure = AllowInsecure,
            WsPath = WsPath,
            WsHost = WsHost,
            GrpcService = GrpcService,
            Extra = new Dictionary<string, JsonElement>(Extra.Count),
        };
        foreach (var pair in Extra)
        {
            // Clone() отвязывает элемент от исходного JsonDocument: иначе копия
            // умрёт вместе с документом, из которого читался профиль.
            copy.Extra[pair.Key] = pair.Value.Clone();
        }
        return copy;
    }
}
