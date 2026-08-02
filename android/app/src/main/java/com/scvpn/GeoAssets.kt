package com.scvpn

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Гео-базы для режима «Авто» (российские сайты напрямую).
 *
 * Правила `geosite:category-ru` и `geoip:ru` ядро разбирает по файлам
 * geosite.dat / geoip.dat. Они лежат внутри libv2ray.aar и попадают в APK как
 * ассеты, но ядро читает не ассеты, а обычные файлы — поэтому при первом
 * запуске один раз копируем их в filesDir, туда же, куда смотрит initCoreEnv.
 *
 * Вместе ~28 МБ, копирование заметное, поэтому делаем это ровно один раз:
 * повторный запуск видит файлы нужного размера и ничего не трогает.
 */
object GeoAssets {
    private const val TAG = "SCVPN"
    private val FILES = listOf("geoip.dat", "geosite.dat")

    /** Скопировать базы, если их ещё нет. Возвращает true, если всё на месте. */
    fun ensure(ctx: Context): Boolean {
        var ok = true
        for (name in FILES) {
            val dst = File(ctx.filesDir, name)
            val size = runCatching { ctx.assets.openFd(name).length }.getOrNull()
                ?: runCatching {
                    // Ассет может быть сжат — тогда openFd не работает и длину
                    // узнаём только чтением. Сверяем по факту наличия файла.
                    if (dst.exists() && dst.length() > 0) dst.length() else -1L
                }.getOrDefault(-1L)

            if (dst.exists() && size > 0 && dst.length() == size) continue
            if (dst.exists() && size <= 0 && dst.length() > 0) continue

            ok = copy(ctx, name, dst) && ok
        }
        return ok
    }

    private fun copy(ctx: Context, name: String, dst: File): Boolean = try {
        ctx.assets.open(name).use { input ->
            // Пишем во временный файл и переименовываем: если копирование
            // прервётся, ядро не подхватит обрезанную базу.
            val tmp = File(dst.parentFile, "$name.part")
            tmp.outputStream().use { input.copyTo(it, 128 * 1024) }
            if (dst.exists()) dst.delete()
            tmp.renameTo(dst)
        }
        Log.i(TAG, "гео-база $name готова (${dst.length()} байт)")
        true
    } catch (e: Exception) {
        Log.e(TAG, "не удалось подготовить $name", e)
        false
    }

    /** Есть ли базы на месте — без них режим «Авто» смысла не имеет. */
    fun ready(ctx: Context): Boolean =
        FILES.all { File(ctx.filesDir, it).length() > 0 }
}
