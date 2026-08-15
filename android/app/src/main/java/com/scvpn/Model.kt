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
            val sec = if (security.isBlank() || security == "none") "" else "+$security"
            return "$protocol$sec / $network"
        }

    /** Грубый ключ для отсева дубликатов. */
    fun key(): String = "$protocol://${uuid.ifBlank { password }}@$address:$port/$network/$security"

    fun toJson(): JSONObject = JSONObject().apply {
        put("protocol", protocol); put("name", name); put("address", address); put("port", port)
        put("uuid", uuid); put("password", password); put("method", method); put("alterId", alterId)
        put("network", network); put("security", security); put("flow", flow); put("sni", sni)
        put("fingerprint", fingerprint); put("alpn", alpn); put("publicKey", publicKey)
        put("shortId", shortId); put("spiderX", spiderX); put("wsPath", wsPath); put("wsHost", wsHost)
        put("grpcService", grpcService); put("allowInsecure", allowInsecure)
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
