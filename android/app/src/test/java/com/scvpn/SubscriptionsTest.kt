package com.scvpn

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Проверки слияния подписок. Устройства не требуют: чистые функции над
 * списками.
 */
class SubscriptionsTest {

    private fun server(name: String, sub: String = "") =
        Server(name = name, address = "$name.example", uuid = name, sub = sub)

    private val manual = server("вручную")
    private val fromA = server("A1", sub = "https://a/sub")
    private val fromB = server("B1", sub = "https://b/sub")

    @Test
    fun `обновление подписки не трогает серверы, добавленные вручную`() {
        val after = Subscriptions.merge(
            existing = listOf(manual, fromA),
            incoming = listOf(server("A2")),
            url = "https://a/sub",
        )
        assertEquals(listOf("вручную", "A2"), after.map { it.name })
    }

    @Test
    fun `обновление одной подписки не трогает другую`() {
        val after = Subscriptions.merge(
            existing = listOf(fromA, fromB),
            incoming = listOf(server("A2")),
            url = "https://a/sub",
        )
        assertEquals(listOf("B1", "A2"), after.map { it.name })
    }

    @Test
    fun `пришедшие серверы помечаются своей подпиской`() {
        val after = Subscriptions.merge(emptyList(), listOf(server("A1")), "https://a/sub")
        assertEquals("https://a/sub", after.single().sub)
    }

    @Test
    fun `удаление подписки уносит только её серверы`() {
        val after = Subscriptions.remove(listOf(manual, fromA, fromB), "https://a/sub")
        assertEquals(listOf("вручную", "B1"), after.map { it.name })
    }

    @Test
    fun `выбранный сервер переезжает по ключу, а не по индексу`() {
        val servers = listOf(manual, fromB, fromA)
        assertEquals(2, Subscriptions.selectionAfterMerge(servers, fromA.key()))
    }

    @Test
    fun `исчезнувший выбор откатывается на первый сервер`() {
        assertEquals(0, Subscriptions.selectionAfterMerge(listOf(manual), fromA.key()))
    }
}

/// Дубликаты серверов, добавленных ссылкой.
class AddUniqueTest {

    private fun server(name: String, uuid: String = "u") =
        Server(name = name, address = "a.example", uuid = uuid)

    @Test
    fun `тот же сервер второй раз не добавляется`() {
        val first = Subscriptions.addUnique(emptyList(), server("дом"))!!
        assertEquals(null, Subscriptions.addUnique(first, server("дом")))
    }

    @Test
    fun `имя в ключ не входит`() {
        val first = Subscriptions.addUnique(emptyList(), server("дом"))!!
        assertEquals(null, Subscriptions.addUnique(first, server("работа")))
    }

    @Test
    fun `другой сервер добавляется`() {
        val first = Subscriptions.addUnique(emptyList(), server("дом", uuid = "one"))!!
        val second = Subscriptions.addUnique(first, server("дача", uuid = "two"))
        assertEquals(listOf("дом", "дача"), second?.map { it.name })
    }
}
