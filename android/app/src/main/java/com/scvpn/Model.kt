package com.scvpn

import org.json.JSONObject

/**
 * Модель одного VPN-сервера (порт с десктопной версии SCVPN).
 * Поля повторяют параметры ссылок vless/vmess/trojan/ss.
 */
data class Server(
    var protocol: String = "vless",
    var name: String = "",
    var address: String = "",
    var port: Int = 443,
    var uuid: String = "",
    var password: String = "",
    var method: String = "",
    var alterId: Int = 0,
    var network: String = "tcp",
    var security: String = "none",
    var flow: String = "",
    var sni: String = "",
    var fingerprint: String = "",
    var alpn: String = "",
    var publicKey: String = "",
    var shortId: String = "",
    var spiderX: String = "/",
    var wsPath: String = "/",
    var wsHost: String = "",
    var grpcService: String = "",
    var allowInsecure: Boolean = false,
    // --- wireguard / AmneziaWG ---
    // Публичный ключ пира лежит в общем `publicKey`: у Reality то же поле
    // значит то же самое — «публичный ключ сервера», и отдельное имя на диске
    // только размножило бы ключи ради одного и того же смысла.
    var privateKey: String = "",
    var presharedKey: String = "",
    /** Адреса интерфейса через запятую: `10.66.66.4/32,fd42:42:42::4/128`. */
    var localAddress: String = "",
    /** Через запятую; пусто — полный набор `0.0.0.0/0,::/0`. */
    var allowedIPs: String = "",
    /** DNS интерфейса через запятую (не системный DNS приложения). */
    var wgDns: String = "",
    /** 0 — взять умолчание туннеля (1420). */
    var mtu: Int = 0,
    /** 0 — keepalive не слать. */
    var keepalive: Int = 0,
    /**
     * Параметры обфускации AmneziaWG как `jc=10,jmin=47,…` в именах UAPI.
     *
     * Одной строкой намеренно: Amnezia добавляет параметры от версии к версии
     * (jc…h4 были в 1.5, i1…i5 приехали во 2.0), и открытый список избавляет
     * от правки четырёх платформ на каждый новый ключ. Пусто — это обычный
     * WireGuard без обфускации, рабочий режим, а не ошибка.
     */
    var awg: String = "",
    /**
     * Ссылка подписки, из которой пришёл сервер; пусто — добавлен вручную.
     *
     * Без этого поля обновление подписки затирало **весь** список, вместе с
     * серверами, вставленными ссылкой: они пропадали молча. Теперь обновление
     * заменяет только свои.
     */
    var sub: String = ""
) {
    val title: String get() = if (name.isNotBlank()) name else "$address:$port"

    /** Короткая подпись под именем: «vless+reality / tcp». */
    val subtitle: String
        get() {
            // У wireguard `security` и `network` — заглушки (none/tcp): они
            // остались от полей Xray и о сервере не говорят ничего. Показывать
            // их значило бы врать, поэтому подпись собирается своя.
            if (protocol == "wireguard") {
                return if (awg.isBlank()) "wireguard" else "wireguard + обфускация"
            }
            val sec = if (security.isBlank() || security == "none") "" else "+$security"
            return "$protocol$sec / $network"
        }

    /**
     * Грубый ключ для отсева дубликатов.
     *
     * У wireguard-сервера нет ни uuid, ни пароля, поэтому два разных пира на
     * одном `host:port` схлопывались бы в одну запись. Третьим запасным идёт
     * публичный ключ — он у пиров как раз разный. Формат строки не меняется:
     * она лежит в настройках как выбранный сервер.
     */
    fun key(): String {
        val secret = uuid.ifBlank { password }.ifBlank { publicKey }
        return "$protocol://$secret@$address:$port/$network/$security"
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("protocol", protocol); put("name", name); put("address", address); put("port", port)
        put("uuid", uuid); put("password", password); put("method", method); put("alterId", alterId)
        put("network", network); put("security", security); put("flow", flow); put("sni", sni)
        put("fingerprint", fingerprint); put("alpn", alpn); put("publicKey", publicKey)
        put("shortId", shortId); put("spiderX", spiderX); put("wsPath", wsPath); put("wsHost", wsHost)
        put("grpcService", grpcService); put("allowInsecure", allowInsecure)
        put("privateKey", privateKey); put("presharedKey", presharedKey)
        put("localAddress", localAddress); put("allowedIPs", allowedIPs)
        put("wgDns", wgDns); put("mtu", mtu); put("keepalive", keepalive); put("awg", awg)
        put("sub", sub)
    }

    companion object {
        fun fromJson(o: JSONObject): Server = Server(
            protocol = o.optString("protocol", "vless"),
            name = o.optString("name"),
            address = o.optString("address"),
            port = o.optInt("port", 443),
            uuid = o.optString("uuid"),
            password = o.optString("password"),
            method = o.optString("method"),
            alterId = o.optInt("alterId", 0),
            network = o.optString("network", "tcp"),
            security = o.optString("security", "none"),
            flow = o.optString("flow"),
            sni = o.optString("sni"),
            fingerprint = o.optString("fingerprint"),
            alpn = o.optString("alpn"),
            publicKey = o.optString("publicKey"),
            shortId = o.optString("shortId"),
            spiderX = o.optString("spiderX", "/"),
            wsPath = o.optString("wsPath", "/"),
            wsHost = o.optString("wsHost"),
            grpcService = o.optString("grpcService"),
            allowInsecure = o.optBoolean("allowInsecure", false),
            privateKey = o.optString("privateKey"),
            presharedKey = o.optString("presharedKey"),
            localAddress = o.optString("localAddress"),
            allowedIPs = o.optString("allowedIPs"),
            wgDns = o.optString("wgDns"),
            mtu = o.optInt("mtu", 0),
            keepalive = o.optInt("keepalive", 0),
            awg = o.optString("awg"),
            // Записи прошлых версий поля не знают — для них подписка пустая,
            // то есть сервер считается добавленным вручную и не удаляется
            // при обновлении.
            sub = o.optString("sub")
        )
    }
}

/**
 * Выбор рабочего TLS-отпечатка.
 * В свежем Xray `chrome` шлёт пост-квантовую кривую → часть серверов виснет,
 * а `randomized` нестабилен. Поэтому такие значения заменяем на firefox
 * (проверено: на серверах пользователя работает).
 */
fun sanitizeFingerprint(fp: String): String {
    val f = fp.trim().lowercase()
    return if (f.isBlank() || f == "chrome" || f == "randomized" || f == "random") "firefox" else f
}
