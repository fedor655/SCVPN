package com.scvpn

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings
import java.security.MessageDigest

/**
 * Идентификатор устройства для панелей с привязкой к устройствам (HWID).
 *
 * Панели вроде Remnawave ограничивают число устройств на аккаунт и требуют
 * заголовок `x-hwid`. Без него подписка отдаёт не серверы, а заглушку
 * `vless://0000...@0.0.0.0:1#App not supported` — именно она и появлялась
 * в списке серверов отдельной непонятной строкой.
 *
 * Наружу уходит не ANDROID_ID, а его SHA-256 с солью: провайдеру нужно только
 * стабильное «это то же устройство». Значение считается один раз и хранится
 * в настройках — если его менять, каждый раз занимался бы новый слот.
 */
object Hwid {
    private const val SALT = "scvpn-hwid-v1"

    @SuppressLint("HardwareIds")
    private fun source(ctx: Context): String {
        val id = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID)
        return if (!id.isNullOrBlank()) id else "fallback-${Build.FINGERPRINT}"
    }

    fun deviceId(ctx: Context): String {
        Prefs.hwid(ctx).takeIf { it.isNotBlank() }?.let { return it }

        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$SALT:${source(ctx)}".toByteArray())
            .joinToString("") { "%02x".format(it) }
        // Формат UUID — панели ожидают его чаще всего и точно принимают.
        val hwid = "${digest.substring(0, 8)}-${digest.substring(8, 12)}-" +
            "${digest.substring(12, 16)}-${digest.substring(16, 20)}-${digest.substring(20, 32)}"

        Prefs.setHwid(ctx, hwid)
        return hwid
    }

    fun headers(ctx: Context): Map<String, String> = mapOf(
        "x-hwid" to deviceId(ctx),
        "x-device-os" to "Android",
        "x-ver-os" to Build.VERSION.RELEASE.orEmpty(),
        "x-device-model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
    )
}
