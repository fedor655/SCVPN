package com.scvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import com.v2ray.ang.service.TProxyService
import java.io.File

/**
 * VPN-сервис: VpnService(TUN) -> hev-мост -> Xray(socks) -> сервер.
 * Петля исключена через addDisallowedApplication(своё приложение) —
 * трафик самого Xray к серверу идёт мимо TUN.
 *
 * Подъём вынесен в отдельный поток: подбор TLS-отпечатка ходит в сеть,
 * а onStartCommand выполняется на главном потоке.
 */
class ScVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.scvpn.START"
        const val ACTION_STOP = "com.scvpn.STOP"
        private const val TAG = "SCVPN"
        private const val CHANNEL = "scvpn_vpn"
        private const val NOTIF_ID = 1
        private const val TUN_ADDR = "26.26.26.1"
        // Адрес IPv6 на том же интерфейсе. Без него маршрут ::/0 не поднять, а
        // без маршрута ::/0 весь IPv6-трафик приложений уходит мимо туннеля
        // напрямую — на сетях операторов с IPv6 это утечка настоящего адреса.
        // Взят ULA (fc00::/7), как у v2rayNG: приложения при выборе адреса
        // источника (RFC 6724) ставят такой IPv6 ниже IPv4, поэтому двустековые
        // сайты идут по IPv4, а в туннель попадает только то, что иначе утекло
        // бы. Цена решения: до чисто-IPv6 хостов достучится лишь тот, у кого
        // сервер сам умеет исходящий IPv6 — зато утечки нет никогда.
        private const val TUN_ADDR6 = "fc00::26:26:26:1"

        /**
         * MTU туннеля.
         *
         * 1500 — обычный канал. Для vless и прочих это ни на что не влияет:
         * TCP разбирает hev-мост, и размер пакета до сервера от этого числа не
         * зависит. У wireguard зависит: UDP-датаграмма доезжает до стека
         * внутри scvpn-awg целиком, а там канал уже 1420 байт — остальное
         * съедает заголовок WireGuard. Всё, что крупнее, режется на фрагменты:
         * лишний расход, а по дороге фрагменты ещё и теряют.
         *
         * Поэтому wireguard-серверу объявляем сразу MTU его собственного
         * туннеля. Число одно на TUN и на hev — мост собирает пакеты по нему
         * же, и разойтись им нельзя.
         */
        private const val MTU = 1500

        @Volatile var isRunning = false
            private set
    }

    private var tun: ParcelFileDescriptor? = null
    private var worker: Thread? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopVpn()
            return START_NOT_STICKY
        }

        val server = Prefs.selectedServer(applicationContext)
        if (server == null) {
            fail("Не выбран сервер")
            return START_NOT_STICKY
        }

        // Уведомление обязано появиться синхронно — иначе система убьёт сервис
        // за то, что startForegroundService не превратился в foreground вовремя.
        startForeground(NOTIF_ID, buildNotification(server.title, connected = false))
        VpnBus.publish(this, VpnState.CONNECTING, server.title)

        worker?.interrupt()
        worker = Thread { startVpn(server) }.also { it.start() }
        return START_STICKY
    }

    private fun startVpn(server: Server) {
        try {
            // 1) поднять TUN
            val mtu = mtuFor(server)
            val builder = Builder()
                .setSession("SCVPN")
                .setMtu(mtu)
                .addAddress(TUN_ADDR, 30)
                .addRoute("0.0.0.0", 0)
                .addAddress(TUN_ADDR6, 126)
                .addRoute("::", 0)
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")

            // Раздельное туннелирование + исключение самого приложения:
            // и то и другое трогает один и тот же список, поэтому делается
            // в одном месте (см. SplitTunnel.apply).
            val split = SplitTunnel.apply(
                builder, packageManager,
                Prefs.splitMode(applicationContext),
                Prefs.splitApps(applicationContext),
                packageName,
            )
            Log.i(TAG, "туннель охватывает: $split")
            CoreLog.add("туннель охватывает: $split")
            val pfd = builder.establish() ?: throw IllegalStateException("establish() вернул null")
            tun = pfd

            // 2) для wireguard — поднять scvpn-awg и дождаться его готовности.
            // Строго до Xray: его socks-выход смотрит в этот порт, и запуск в
            // обратном порядке дал бы окно, в котором трафик идти некуда.
            if (server.protocol == "wireguard" &&
                !AwgProcess.start(applicationContext, server, XrayConfig.AWG_PORT)
            ) {
                throw IllegalStateException("AmneziaWG не запустился")
            }

            // 3) запустить Xray (socks на 127.0.0.1:10808)
            val config = XrayConfig.build(
                server, routeMode = Prefs.routeMode(applicationContext)
            )
            if (!XrayCore.start(applicationContext, config)) {
                throw IllegalStateException("Xray не запустился")
            }

            // 4) запустить hev-мост: TUN <-> socks
            val yaml = buildHevConfig(mtu)
            val cfgFile = File(filesDir, "hev.yaml").apply { writeText(yaml) }
            TProxyService.TProxyStartService(cfgFile.absolutePath, pfd.fd)

            isRunning = true
            val since = SystemClock.elapsedRealtime()
            notify(buildNotification(server.title, connected = true))
            VpnBus.publish(this, VpnState.CONNECTED, server.title, since)
            Log.i(TAG, "VPN запущен: ${server.title}")
            CoreLog.add("VPN запущен: ${server.title}")
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка запуска VPN", e)
            CoreLog.add("ошибка запуска: ${e.message}")
            cleanup()
            fail(e.message ?: "не удалось подключиться")
        }
    }

    private fun stopVpn() {
        worker?.interrupt()
        worker = null
        cleanup()
        CoreLog.add("VPN остановлен")
        VpnBus.publish(this, VpnState.IDLE)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Погасить ядро и адаптер, не трогая состояние сервиса. */
    private fun cleanup() {
        try { TProxyService.TProxyStopService() } catch (e: Exception) { Log.e(TAG, "hev stop", e) }
        XrayCore.stop()
        // В обратном порядке: пока Xray жив, он держит соединения через
        // scvpn-awg, и гасить туннель под ними незачем. Зовётся всегда, даже
        // если сервер не wireguard, — процесс мог остаться от прошлого
        // подключения, а второй запуск упёрся бы в занятый порт.
        AwgProcess.stop()
        try { tun?.close() } catch (e: Exception) { Log.e(TAG, "tun close", e) }
        tun = null
        isRunning = false
    }

    private fun fail(message: String) {
        VpnBus.publish(this, VpnState.ERROR, message)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        Log.w(TAG, "VPN отозван системой")
        CoreLog.add("VPN отозван системой")
        stopVpn()
    }

    override fun onDestroy() {
        if (isRunning) {
            cleanup()
            VpnBus.publish(this, VpnState.IDLE)
        }
        super.onDestroy()
    }

    /** См. комментарий к MTU: у wireguard канал уже, и врать об этом нельзя. */
    private fun mtuFor(server: Server): Int =
        if (server.protocol != "wireguard") MTU
        else if (server.mtu > 0) server.mtu else AwgProcess.DEFAULT_MTU

    private fun buildHevConfig(mtu: Int): String = buildString {
        appendLine("tunnel:")
        appendLine("  mtu: $mtu")
        appendLine("  ipv4: $TUN_ADDR")
        // Кавычки обязательны: без них hev читает адрес не как строку.
        appendLine("  ipv6: '$TUN_ADDR6'")
        appendLine("socks5:")
        appendLine("  port: ${XrayConfig.SOCKS_PORT}")
        appendLine("  address: 127.0.0.1")
        appendLine("  udp: 'udp'")
        appendLine("misc:")
        appendLine("  tcp-read-write-timeout: 300000")
        appendLine("  udp-read-write-timeout: 60000")
        appendLine("  log-level: warn")
    }

    private fun notify(n: Notification) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, n)
    }

    private fun buildNotification(serverTitle: String, connected: Boolean): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, "SCVPN", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ScVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle(if (connected) "SCVPN подключён" else "SCVPN подключается…")
            .setContentText(serverTitle)
            .setSmallIcon(R.drawable.ic_stat_scvpn)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .addAction(0, "Отключить", stop)
            .build()
    }
}
