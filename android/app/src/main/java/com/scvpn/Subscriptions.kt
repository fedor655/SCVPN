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

    /**
     * Добавить сервер, если такого ещё нет.
     *
     * `null` — дубликат: человек вставляет одну и ту же ссылку чаще, чем
     * кажется, и список из десяти одинаковых строк выглядит как поломка.
     * Ключ тот же, что при обновлении подписки, — имя в него не входит.
     */
    fun addUnique(existing: List<Server>, server: Server): List<Server>? =
        if (existing.any { it.key() == server.key() }) null else existing + server

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
