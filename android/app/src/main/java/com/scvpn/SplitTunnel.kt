package com.scvpn

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.drawable.Drawable

/**
 * Раздельное туннелирование: какие приложения пускать через VPN.
 *
 * На Android это штатная возможность VpnService: список приложений задаётся
 * при подъёме туннеля и дальше меняться не может — поэтому изменения
 * применяются при следующем подключении, а не на лету.
 *
 * Режимы намеренно повторяют десктопные, чтобы настройка на обеих платформах
 * называлась и вела себя одинаково.
 */
object SplitTunnel {
    const val OFF = "off"           // все приложения через VPN
    const val EXCLUDE = "exclude"   // все через VPN, кроме выбранных
    const val INCLUDE = "include"   // только выбранные через VPN

    data class AppEntry(
        val packageName: String,
        val label: String,
        val icon: Drawable?,
        val isSystem: Boolean,
    )

    /**
     * Приложения для списка выбора: те, у которых есть интернет-разрешение,
     * — остальным туннель всё равно ни к чему. Своё приложение исключаем:
     * оно и так всегда идёт мимо туннеля, иначе Xray заворачивал бы сам себя.
     */
    fun installedApps(ctx: Context, includeSystem: Boolean = false): List<AppEntry> {
        val pm = ctx.packageManager
        val self = ctx.packageName

        @Suppress("DEPRECATION")
        val packages = pm.getInstalledPackages(PackageManager.GET_PERMISSIONS)

        return packages.asSequence()
            .filter { it.packageName != self }
            .filter { it.requestedPermissions?.contains(android.Manifest.permission.INTERNET) == true }
            .mapNotNull { pkg ->
                val info: ApplicationInfo = pkg.applicationInfo ?: return@mapNotNull null
                val isSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                // Системные показываем только по запросу: их сотни, и в списке
                // они прячут то немногое, что человек реально ищет.
                val launchable = pm.getLaunchIntentForPackage(pkg.packageName) != null
                if (isSystem && !includeSystem && !launchable) return@mapNotNull null
                AppEntry(
                    packageName = pkg.packageName,
                    label = pm.getApplicationLabel(info).toString(),
                    icon = runCatching { pm.getApplicationIcon(info) }.getOrNull(),
                    isSystem = isSystem,
                )
            }
            .sortedBy { it.label.lowercase() }
            .toList()
    }

    /**
     * Применить режим к строящемуся туннелю и заодно убрать из него само
     * приложение (иначе Xray заворачивал бы свой трафик к серверу сам в себя).
     *
     * Важно: Android не разрешает смешивать `addAllowedApplication` и
     * `addDisallowedApplication` — второй вызов бросит исключение. Поэтому в
     * режиме «только выбранные» своё приложение не исключаем отдельно: оно и
     * так не попадает в туннель, раз его нет в списке разрешённых.
     *
     * Пакеты, которых уже нет на устройстве, пропускаем молча: иначе
     * подключение срывалось бы из-за давно удалённой программы.
     */
    fun apply(
        builder: android.net.VpnService.Builder,
        pm: PackageManager,
        mode: String,
        packages: Set<String>,
        selfPackage: String,
    ): String {
        val wanted = packages - selfPackage
        val useAllowList = mode == INCLUDE && wanted.isNotEmpty()

        var applied = 0
        var missing = 0
        for (name in wanted) {
            if (mode == OFF) break
            if (runCatching { pm.getPackageInfo(name, 0) }.isFailure) { missing++; continue }
            val ok = runCatching {
                if (useAllowList) builder.addAllowedApplication(name)
                else builder.addDisallowedApplication(name)
            }.isSuccess
            if (ok) applied++ else missing++
        }

        if (!useAllowList) {
            // Режимы «всё» и «кроме выбранных» — обычный чёрный список,
            // в который добавляем и себя.
            runCatching { builder.addDisallowedApplication(selfPackage) }
        }

        if (mode == OFF || applied == 0) {
            // В режиме «только выбранные» пустой список дал бы туннель, в
            // котором вообще нет трафика. Честнее пустить всё.
            return if (mode == OFF) "все приложения" else "все приложения (выбранные не найдены)"
        }

        val what = if (useAllowList) "только выбранные" else "все, кроме выбранных"
        return "$what: $applied" + if (missing > 0) " (пропущено недоступных: $missing)" else ""
    }
}
