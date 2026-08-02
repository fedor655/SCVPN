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
        // envPath — папка, где ядро ищет ассеты/сертификаты (geo не используем).
        Libv2ray.initCoreEnv(ctx.filesDir.absolutePath, "")
    }

    fun start(ctx: Context, configJson: String): Boolean {
        if (isRunning) stop()
        ensureEnv(ctx)
        val c = Libv2ray.newCoreController(object : CoreCallbackHandler {
            override fun startup(): Long = 0
            override fun shutdown(): Long = 0
            override fun onEmitStatus(l: Long, s: String?): Long {
                Log.i(TAG, "xray: $s"); return 0
            }
        })
        return try {
            c.startLoop(configJson, 0)
            controller = c
            c.isRunning
        } catch (e: Exception) {
            Log.e(TAG, "startLoop failed", e)
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
        val needsFp = server.security == "reality" || server.security == "tls"
        val candidates = if (!needsFp || server.fingerprint.isNotBlank())
            listOf(server.fingerprint)
        else
            listOf("firefox", "safari", "edge", "ios")

        for (fp in candidates) {
            val probe = server.copy(fingerprint = fp)
            val ms = measureDelay(ctx, XrayConfig.buildForPing(probe))
            if (ms > 0) {
                if (needsFp) server.fingerprint = sanitizeFingerprint(fp)
                return ms
            }
        }
        return -1
    }
}
