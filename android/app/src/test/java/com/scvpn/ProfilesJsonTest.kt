package com.scvpn

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Формат обмена с десктопом. Ключи заморожены: их правка ломает чтение чужих
 * файлов, а замечает это пользователь, у которого перенос потерял половину
 * настроек сервера.
 */
class ProfilesJsonTest {

    private fun reality() = Server(
        protocol = "vless", name = "Прага", address = "a.example", port = 443,
        uuid = "u-1", network = "tcp", security = "reality", flow = "xtls-rprx-vision",
        sni = "ya.ru", fingerprint = "chrome", publicKey = "pk", shortId = "sid",
        spiderX = "/x", wsPath = "/ws", wsHost = "h", grpcService = "g",
        alterId = 3, allowInsecure = true,
    )

    @Test
    fun `имена ключей совпадают с десктопными`() {
        val o = ProfilesJson.serverToJson(reality())
        for (key in listOf("protocol", "alter_id", "public_key", "short_id", "spider_x",
                           "allow_insecure", "ws_path", "ws_host", "grpc_service")) {
            assertTrue("нет ключа $key", o.has(key))
        }
    }

    @Test
    fun `круг запись-чтение не теряет полей`() {
        val back = ProfilesJson.serverFromJson(ProfilesJson.serverToJson(reality()))
        assertEquals(reality(), back)
    }

    @Test
    fun `серверы подписки уезжают внутрь неё, а не в общий список`() {
        val sub = Prefs.Sub("https://panel/sub", SubInfo(title = "Панель"), "2026-08-16 07:00")
        val servers = listOf(reality(), reality().copy(name = "из подписки", sub = sub.url))
        val root = ProfilesJson.export(servers, listOf(sub))

        assertEquals(1, root.getJSONArray("servers").length())
        val subs = root.getJSONArray("subscriptions")
        assertEquals(1, subs.length())
        assertEquals(1, subs.getJSONObject(0).getJSONArray("servers").length())
    }

    @Test
    fun `при чтении сервер подписки помечается её ссылкой`() {
        val sub = Prefs.Sub("https://panel/sub", SubInfo(), "")
        val root = ProfilesJson.export(listOf(reality().copy(sub = sub.url)), listOf(sub))
        val imported = ProfilesJson.import(root)
        assertEquals("https://panel/sub", imported.servers.single().sub)
        assertEquals(listOf("https://panel/sub"), imported.subs.map { it.url })
    }

    @Test
    fun `файл десктопа без подписок читается`() {
        val root = JSONObject("""{"servers":[{"protocol":"trojan","address":"b.example",
            "port":8443,"password":"p","security":"tls"}],"subscriptions":[]}""")
        val imported = ProfilesJson.import(root)
        assertEquals("b.example", imported.servers.single().address)
        assertEquals("p", imported.servers.single().password)
    }

    @Test
    fun `повторный импорт не плодит дубликаты`() {
        val existing = listOf(reality())
        val merged = ProfilesJson.mergeInto(existing, listOf(reality(), reality().copy(name = "новый")))
        // Имя в ключ не входит: тот же сервер под другим именем — тот же сервер.
        assertEquals(1, merged.size)
    }

    @Test
    fun `новый сервер при импорте добавляется`() {
        val merged = ProfilesJson.mergeInto(
            listOf(reality()),
            listOf(reality().copy(address = "c.example", uuid = "u-2")),
        )
        assertEquals(listOf("a.example", "c.example"), merged.map { it.address })
    }
}
