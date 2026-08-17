package com.scvpn

import android.content.Context
import android.util.Log
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray

/**
 * Обёртка над открытым ядром Xray (libv2ray.aar).
 * Запускает Xray внутри процесса приложения; SOCKS-инбаунд слушает 127.0.0.1.
 * tunFd=0 — встроенный TUN ядра не используем, трафик заводит hev-мост.
 */
object XrayCore {
    private const val TAG = "SCVPN"
    private var controller: CoreController? = null

    val isRunning: Boolean get() = controller?.isRunning == true

    private fun ensureEnv(ctx: Context) {
        // envPath — папка, где ядро ищет гео-базы. Их туда кладёт GeoAssets:
        // без них режим «Авто» не разберёт российские домены.
        GeoAssets.ensure(ctx)
        Libv2ray.initCoreEnv(ctx.filesDir.absolutePath, "")
    }

    fun start(ctx: Context, configJson: String): Boolean {
        if (isRunning) stop()
        ensureEnv(ctx)
        val c = Libv2ray.newCoreController(object : CoreCallbackHandler {
            override fun startup(): Long = 0
            override fun shutdown(): Long = 0
            override fun onEmitStatus(l: Long, s: String?): Long {
                // То же сообщение вдобавок кладётся в CoreLog: без него
                // сказанное ядром видно только через adb logcat.
                Log.i(TAG, "xray: $s"); CoreLog.add("xray: $s"); return 0
            }
        })
        return try {
            c.startLoop(configJson, 0)
            controller = c
            c.isRunning
        } catch (e: Exception) {
            Log.e(TAG, "startLoop failed", e)
            CoreLog.add("ядро не запустилось: ${e.message}")
            false
        }
    }

    fun stop() {
        try { controller?.stopLoop() } catch (e: Exception) { Log.e(TAG, "stopLoop", e) }
        controller = null
    }

    /** Замер задержки конфигом (для пинга/автоподбора). -1 при неудаче. */
    fun measureDelay(ctx: Context, configJson: String): Long {
        ensureEnv(ctx)
        return try {
            Libv2ray.measureOutboundDelay(configJson, "https://www.gstatic.com/generate_204")
        } catch (e: Exception) {
            -1
        }
    }

    /**
     * Задержка до сервера с автоподбором отпечатка.
     * Возвращает мс или -1. Заодно фиксирует в сервере отпечаток, который
     * реально ответил, — тем же приёмом, что и десктопный `connect.py`.
     */
    fun pingServer(ctx: Context, server: Server): Long {
        // У wireguard TLS нет вовсе: `security` у него заглушка `none`, и
        // перебор отпечатков гонял бы один и тот же замер четыре раза впустую.
        // Проверка по протоколу, а не по одному лишь `security`: заглушку в
        // профиле могли переписать руками.
        val needsFp = server.protocol != "wireguard" &&
            (server.security == "reality" || server.security == "tls")
        val candidates = if (!needsFp || server.fingerprint.isNotBlank())
            listOf(server.fingerprint)
        else
            listOf("firefox", "safari", "edge", "ios")

        for (fp in candidates) {
            val probe = server.copy(fingerprint = fp)
            // Сборка конфига падает на незнакомом протоколе. Это ошибка записи,
            // а не сети, и ронять из-за неё замер всего списка незачем.
            val config = runCatching { XrayConfig.buildForPing(probe) }.getOrNull() ?: return -1
            val ms = measureDelay(ctx, config)
            if (ms > 0) {
                if (needsFp) server.fingerprint = sanitizeFingerprint(fp)
                return ms
            }
        }
        return -1
    }
}
