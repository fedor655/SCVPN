package com.scvpn

import android.util.Base64
import java.net.HttpURLConnection
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import org.json.JSONObject

/**
 * Служебные сведения о подписке из заголовков ответа панели.
 * Полный порт desktop/scvpn/subinfo.py — поля и разбор совпадают, чтобы
 * на обеих платформах показывались одни и те же цифры.
 *
 * Ничего не досчитываем: сколько потрачено и когда истекает — считает панель.
 */
data class SubInfo(
    var title: String = "",
    var account: String = "",
    var upload: Long = 0,
    var download: Long = 0,
    var total: Long = 0,          // 0 = безлимит
    var expire: Long = 0,         // unix-секунды, 0 = бессрочно
    var updateInterval: Int = 0,  // часы
    var supportUrl: String = "",
    var announce: String = "",
    var fetched: String = "",
    var deviceLimitReached: Boolean = false,
) {
    val used: Long get() = upload + download
    val unlimited: Boolean get() = total <= 0

    val daysLeft: Int?
        get() = if (expire <= 0) null
        else ((expire * 1000 - System.currentTimeMillis()) / 86_400_000L).toInt()

    val expiresText: String
        get() = if (expire <= 0) "бессрочно"
        else SimpleDateFormat("dd.MM.yyyy", Locale.getDefault()).format(Date(expire * 1000))

    fun toJson(): JSONObject = JSONObject().apply {
        put("title", title); put("account", account)
        put("upload", upload); put("download", download); put("total", total)
        put("expire", expire); put("updateInterval", updateInterval)
        put("supportUrl", supportUrl); put("announce", announce)
        put("fetched", fetched); put("deviceLimitReached", deviceLimitReached)
    }

    companion object {
        fun fromJson(o: JSONObject) = SubInfo(
            title = o.optString("title"), account = o.optString("account"),
            upload = o.optLong("upload"), download = o.optLong("download"),
            total = o.optLong("total"), expire = o.optLong("expire"),
            updateInterval = o.optInt("updateInterval"),
            supportUrl = o.optString("supportUrl"), announce = o.optString("announce"),
            fetched = o.optString("fetched"),
            deviceLimitReached = o.optBoolean("deviceLimitReached"),
        )

        /** Отметка времени в том же виде, что и `fetched`. */
        fun nowStamp(): String =
            SimpleDateFormat("dd.MM.yyyy HH:mm", Locale.getDefault()).format(Date())

        private fun maybeBase64(v: String): String {
            if (!v.startsWith("base64:")) return v
            return runCatching {
                String(Base64.decode(v.substring(7), Base64.DEFAULT), Charsets.UTF_8)
            }.getOrDefault(v)
        }

        fun fromHeaders(conn: HttpURLConnection): SubInfo {
            fun h(name: String) = conn.getHeaderField(name).orEmpty()

            val info = SubInfo(
                title = maybeBase64(h("profile-title")),
                announce = maybeBase64(h("announce")),
                supportUrl = h("support-url"),
                fetched = nowStamp(),
                deviceLimitReached = h("x-hwid-max-devices-reached").lowercase() == "true",
            )

            val disp = h("content-disposition")
            if (disp.contains("filename=")) {
                info.account = disp.substringAfter("filename=").trim().trim('"', ';', ' ')
            }

            // subscription-userinfo: upload=0; download=123; total=0; expire=1788405825
            for (part in h("subscription-userinfo").split(";")) {
                val kv = part.split("=", limit = 2)
                if (kv.size != 2) continue
                val key = kv[0].trim()
                val value = kv[1].trim().toDoubleOrNull()?.toLong() ?: continue
                when (key) {
                    "upload" -> info.upload = value
                    "download" -> info.download = value
                    "total" -> info.total = value
                    "expire" -> info.expire = value
                }
            }

            info.updateInterval = h("profile-update-interval").toIntOrNull() ?: 0
            return info
        }

        fun humanBytes(n: Long): String {
            if (n <= 0) return "0 Б"
            val units = listOf(
                "ТБ" to (1L shl 40), "ГБ" to (1L shl 30),
                "МБ" to (1L shl 20), "КБ" to (1L shl 10),
            )
            for ((unit, size) in units) {
                if (n >= size) return String.format(Locale.getDefault(), "%.2f %s", n.toDouble() / size, unit)
            }
            return "$n Б"
        }

        /** Панели присылают интервал автообновления в часах. */
        fun humanInterval(hours: Int): String = when {
            hours <= 0 -> "не задано"
            hours % 24 == 0 -> if (hours / 24 > 1) "раз в ${hours / 24} дн." else "раз в сутки"
            else -> "раз в $hours ч."
        }
    }
}
