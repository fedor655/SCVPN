package com.scvpn

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * AmneziaWG отдельным процессом: `scvpn-awg` поднимает туннель и отдаёт его
 * наружу как SOCKS5 на 127.0.0.1, а Xray ходит в этот порт обычным
 * socks-выходом. Маршрутизация, DNS, раздельное туннелирование и мост в TUN
 * от этого не меняются вообще — они и так работают через SOCKS.
 *
 * **Почему процесс, а не библиотека.** Ядро AmneziaWG написано на Go, и
 * внутри процесса уже живёт другая Go-среда — та, что внутри `libv2ray.aar`
 * (`libgojni.so`). Две среды Go в одном процессе не уживаются: у каждой свой
 * планировщик, свои обработчики сигналов и свой сборщик мусора. Отдельный
 * процесс снимает вопрос целиком.
 *
 * **Почему бинарник лежит в jniLibs.** С Android 10 приложение не может
 * запускать файлы из своей папки данных — исполняемым остаётся только каталог
 * нативных библиотек. Поэтому программа едет в APK под именем
 * `libscvpnawg.so`: система распаковывает её как библиотеку (для этого в
 * манифесте `extractNativeLibs=true`) и ставит бит запуска.
 *
 * Петли не будет: процесс наследует UID приложения, а само приложение
 * исключено из туннеля (см. SplitTunnel.apply). Его UDP к серверу идёт мимо
 * TUN так же, как трафик Xray.
 */
object AwgProcess {
    private const val TAG = "SCVPN"
    private const val BINARY = "libscvpnawg.so"
    private const val CONF = "awg.conf"

    /** Начало строки готовности; её печатает сам бинарник (см. `awg/main.go`). */
    private const val READY = "[awg] готов"

    /** Сколько ждём готовности: это рукопожатие с сервером, а не запуск программы. */
    private const val START_TIMEOUT_MS = 15_000L

    /** MTU туннеля по умолчанию — то же значение, что стоит в бинарнике. */
    const val DEFAULT_MTU = 1420

    @Volatile
    private var process: Process? = null

    /** Активный .conf — держим ссылку, чтобы снести его вместе с процессом. */
    @Volatile
    private var conf: File? = null

    val isRunning: Boolean get() = process?.isAlive == true

    /**
     * Поднять туннель и дождаться, пока он начнёт принимать соединения.
     *
     * Ждём именно строку готовности, а не «процесс жив»: пока не прошло
     * рукопожатие, порт уже слушает, и Xray успел бы отправить в него запрос,
     * который некуда вести.
     */
    fun start(ctx: Context, server: Server, port: Int): Boolean {
        stop()

        val binary = File(ctx.applicationInfo.nativeLibraryDir, BINARY)
        if (!binary.canExecute()) {
            Log.e(TAG, "нет $BINARY в ${binary.parent}")
            CoreLog.add("нет $BINARY — сервер wireguard не поднять, пересобери APK")
            return false
        }

        val conf = writeConf(ctx, server).also { this.conf = it }
        val ready = CountDownLatch(1)

        val p = try {
            ProcessBuilder(
                binary.absolutePath,
                "-config", conf.absolutePath,
                "-socks", "127.0.0.1:$port",
            )
                .directory(ctx.filesDir)
                // Бинарник пишет через log, то есть в stderr. Сливаем потоки:
                // иначе читать пришлось бы два, а порядок строк всё равно
                // восстановить нельзя.
                .redirectErrorStream(true)
                .start()
        } catch (e: Exception) {
            Log.e(TAG, "scvpn-awg не запустился", e)
            CoreLog.add("scvpn-awg не запустился: ${e.message}")
            dropConf()   // файл с ключом уже записан — уносим его за собой
            return false
        }
        process = p

        // Лог читаем обязательно, а не «если понадобится»: непрочитанный буфер
        // трубы заполняется, и процесс встаёт на своём же выводе.
        Thread {
            try {
                p.inputStream.bufferedReader().forEachLine { line ->
                    val text = line.trim()
                    if (text.isEmpty()) return@forEachLine
                    Log.i(TAG, "awg: $text")
                    CoreLog.add("awg: $text")
                    if (text.startsWith(READY)) ready.countDown()
                }
            } catch (e: Exception) {
                // Поток рвётся при остановке процесса — это не происшествие.
                Log.d(TAG, "лог scvpn-awg закрыт: ${e.message}")
            } finally {
                // Процесс кончился — ждать готовности больше не от кого.
                ready.countDown()
            }
        }.apply { isDaemon = true; name = "awg-log" }.start()

        val ok = ready.await(START_TIMEOUT_MS, TimeUnit.MILLISECONDS) && p.isAlive
        if (!ok) {
            CoreLog.add("scvpn-awg не поднял туннель")
            stop()
        }
        return ok
    }

    /**
     * Убрать .conf с диска.
     *
     * Между сеансами он не нужен никому, а лежит в filesDir при
     * `allowBackup="true"` — то есть приватный ключ туннеля уезжал бы в
     * резервную копию устройства и жил там до следующей.
     */
    private fun dropConf() {
        conf?.let { runCatching { it.delete() } }
        conf = null
    }

    fun stop() {
        // Конфиг сносим до проверки процесса: его могло не остаться, если
        // запуск сорвался уже после записи файла, — а ключ в нём тот же.
        dropConf()
        val p = process ?: return
        process = null
        // destroy() — это SIGTERM: по нему бинарник гасит туннель и отпускает
        // сессию. SIGKILL оставил бы её висеть на сервере ещё минуту, и
        // повторное подключение упиралось бы в старое рукопожатие.
        p.destroy()
        // waitFor со сроком появился только в API 26, а minSdk у нас 24, —
        // поэтому ждём опросом. Ждать бесконечно нельзя: отключение не должно
        // зависать вместе с процессом, который не отвечает на сигнал.
        repeat(30) {
            if (runCatching { p.exitValue() }.isSuccess) return
            runCatching { Thread.sleep(100) }
        }
        Log.w(TAG, "scvpn-awg не вышел по сигналу")
    }

    /**
     * Положить .conf рядом с данными приложения.
     *
     * Права сужаем явно, хотя каталог и так закрыт чужим программам: внутри
     * лежит приватный ключ туннеля, то есть пароль от всего трафика, а файл
     * попадает и в резервные копии, и в выгрузку через adb.
     */
    private fun writeConf(ctx: Context, server: Server): File {
        val conf = File(ctx.filesDir, CONF)
        // Права выставляем на пустом файле, до записи ключа: иначе он успел бы
        // полежать доступным всем на время записи.
        if (!conf.exists()) conf.createNewFile()
        conf.setReadable(false, false)
        conf.setReadable(true, true)
        conf.setWritable(false, false)
        conf.setWritable(true, true)
        conf.writeText(buildConf(server))
        return conf
    }

    /**
     * Собрать .conf формата wg-quick из полей сервера.
     *
     * Ключи регистр не различают (их приводит к нижнему сам разбор), но пишем
     * как в файлах панели — так текст читается глазами при разборе жалоб.
     * Пустые поля не выводим вовсе: у бинарника на них свои умолчания, и
     * пустая строка сбила бы их.
     */
    fun buildConf(s: Server): String = buildString {
        appendLine("[Interface]")
        appendLine("PrivateKey = ${s.privateKey}")
        appendLine("Address = ${s.localAddress}")
        if (s.wgDns.isNotBlank()) appendLine("DNS = ${s.wgDns}")
        if (s.mtu > 0) appendLine("MTU = ${s.mtu}")
        // Параметры обфускации хранятся одной строкой в именах UAPI — ровно в
        // том виде, в каком их принимает разбор.
        for (pair in s.awg.split(",")) {
            val text = pair.trim()
            if (text.contains('=')) appendLine(text)
        }
        appendLine()
        appendLine("[Peer]")
        appendLine("PublicKey = ${s.publicKey}")
        if (s.presharedKey.isNotBlank()) appendLine("PresharedKey = ${s.presharedKey}")
        // Скобки вокруг IPv6 обязательны: без них двоеточия адреса неотличимы
        // от двоеточия перед портом.
        val host = if (s.address.contains(':')) "[${s.address}]" else s.address
        appendLine("Endpoint = $host:${s.port}")
        if (s.allowedIPs.isNotBlank()) appendLine("AllowedIPs = ${s.allowedIPs}")
        if (s.keepalive > 0) appendLine("PersistentKeepalive = ${s.keepalive}")
    }
}
