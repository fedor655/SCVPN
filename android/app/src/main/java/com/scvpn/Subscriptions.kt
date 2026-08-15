package com.scvpn

/**
 * Правила слияния списка серверов при обновлении подписки.
 *
 * Вынесено из экрана отдельно, чтобы проверялось без устройства: это ровно то
 * место, где раньше терялись серверы, добавленные вручную.
 */
object Subscriptions {

    /**
     * Заменить серверы подписки `url` пришедшими, не трогая остальные.
     *
     * Порядок важен: чужие серверы остаются на своих местах, свежие уходят в
     * конец — иначе список прыгал бы при каждом обновлении.
     */
    fun merge(existing: List<Server>, incoming: List<Server>, url: String): List<Server> =
        existing.filterNot { it.sub == url } + incoming.map { it.copy(sub = url) }

    /** Убрать подписку целиком вместе с её серверами. */
    fun remove(existing: List<Server>, url: String): List<Server> =
        existing.filterNot { it.sub == url }

    /**
     * Куда переехал выбранный сервер после слияния.
     *
     * Индекс выбора хранится числом, а список пересобирается целиком, поэтому
     * без пересчёта по ключу выбор молча съезжал бы на чужой сервер.
     */
    fun selectionAfterMerge(servers: List<Server>, selectedKey: String?): Int {
        val at = servers.indexOfFirst { it.key() == selectedKey }
        return if (at >= 0) at else 0
    }
}
