package com.scvpn

import android.content.Context
import android.content.Intent

/**
 * Состояние туннеля и его рассылка в интерфейс.
 *
 * Раньше активность просто читала статический флаг сервиса и «угадывала»
 * результат по таймеру. Теперь сервис сам сообщает о каждом переходе —
 * поэтому кнопка не врёт: «Подключение…» держится ровно до реального старта.
 */
enum class VpnState { IDLE, CONNECTING, CONNECTED, ERROR }

object VpnBus {
    const val ACTION_STATE = "com.scvpn.STATE"
    const val EXTRA_STATE = "state"
    const val EXTRA_MESSAGE = "message"
    /** Момент подключения (SystemClock.elapsedRealtime), чтобы считать время сессии. */
    const val EXTRA_SINCE = "since"

    @Volatile var current: VpnState = VpnState.IDLE
        private set

    @Volatile var since: Long = 0L
        private set

    /**
     * Имя сервера, с которым поднят туннель.
     *
     * Экран обязан показывать именно его: выбор в списке можно сменить, а
     * туннель останется на прежнем сервере — конфиг уже у ядра.
     */
    @Volatile var serverTitle: String = ""
        private set

    fun publish(ctx: Context, state: VpnState, message: String = "", since: Long = 0L) {
        current = state
        this.since = since
        // Сообщение при CONNECTED/CONNECTING — это имя сервера; при ошибке там
        // текст отказа, и запоминать его как имя нельзя.
        if (state == VpnState.CONNECTED || state == VpnState.CONNECTING) serverTitle = message
        if (state == VpnState.IDLE) serverTitle = ""
        val i = Intent(ACTION_STATE)
            .setPackage(ctx.packageName)
            .putExtra(EXTRA_STATE, state.name)
            .putExtra(EXTRA_MESSAGE, message)
            .putExtra(EXTRA_SINCE, since)
        ctx.sendBroadcast(i)
    }
}
