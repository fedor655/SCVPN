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

    fun publish(ctx: Context, state: VpnState, message: String = "", since: Long = 0L) {
        current = state
        this.since = since
        val i = Intent(ACTION_STATE)
            .setPackage(ctx.packageName)
            .putExtra(EXTRA_STATE, state.name)
            .putExtra(EXTRA_MESSAGE, message)
            .putExtra(EXTRA_SINCE, since)
        ctx.sendBroadcast(i)
    }
}
