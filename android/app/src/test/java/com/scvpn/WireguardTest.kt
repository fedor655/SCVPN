package com.scvpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AmneziaWG: разбор `.conf` и перенос полей на другие платформы.
 *
 * Ключи сгенерированы для теста и никуда не ведут — те же, что в `awg/conf_test.go`:
 * так обе стороны (разбор в приложении и разбор в бинарнике) проверяются на
 * одном и том же тексте. Настоящему приватному ключу в репозитории делать
 * нечего, это пароль от всего трафика.
 */
class WireguardTest {

    private val privateB64 = "38GCTbJEvBrai7BT7K8SzCJbD92q35iwl98JRQb/gqI="
    private val publicB64 = "DdoK6OyIth4BjEvyRBnH7eUpjOniDyUMiodwzE5CEl8="
    private val pskB64 = "zxrL/zVlGsR8kjYEg5uS7Krt9XmrgNjliUk6NDvaTEE="

    private val conf = """
        # Name = Прага
        [Interface]
        PrivateKey = $privateB64
        Address = 10.66.66.4/32, fd42:42:42::4/128
        DNS = 1.1.1.1,1.0.0.1
        MTU = 1280
        Jc = 10
        Jmin = 47
        Jmax = 129
        S1 = 46
        S2 = 30
        H1 = 1035708199

        [Peer]
        PublicKey = $publicB64
        PresharedKey = $pskB64
        Endpoint = 198.51.100.7:51820
        AllowedIPs = 0.0.0.0/0,::/0
        PersistentKeepalive = 25
    """.trimIndent()

    @Test
    fun `conf разбирается целиком`() {
        val s = SubscriptionParser.parseWgConf(conf)
        assertNotNull(s)
        s!!
        assertEquals("wireguard", s.protocol)
        assertEquals("Прага", s.name)
        assertEquals("198.51.100.7", s.address)
        assertEquals(51820, s.port)
        assertEquals(privateB64, s.privateKey)
        assertEquals(publicB64, s.publicKey)
        assertEquals(pskB64, s.presharedKey)
        // Пробелы после запятой убираются: дальше строка уезжает в .conf для
        // бинарника, и лишний пробел там читался бы как часть адреса.
        assertEquals("10.66.66.4/32,fd42:42:42::4/128", s.localAddress)
        assertEquals("1.1.1.1,1.0.0.1", s.wgDns)
        assertEquals("0.0.0.0/0,::/0", s.allowedIPs)
        assertEquals(1280, s.mtu)
        assertEquals(25, s.keepalive)
    }

    @Test
    fun `параметры обфускации идут в фиксированном порядке`() {
        // Порядок значим: из строки собирается ключ сервера, и при разном
        // порядке один и тот же пир выглядел бы двумя разными.
        assertEquals(
            "jc=10,jmin=47,jmax=129,s1=46,s2=30,h1=1035708199",
            SubscriptionParser.parseWgConf(conf)!!.awg,
        )
    }

    @Test
    fun `обычный WireGuard без обфускации — рабочий случай`() {
        val s = SubscriptionParser.parseWgConf(
            "[Interface]\nPrivateKey = $privateB64\nAddress = 10.0.0.2/32\n" +
                "[Peer]\nPublicKey = $publicB64\nEndpoint = 1.2.3.4:51820\n"
        )
        assertNotNull(s)
        assertEquals("", s!!.awg)
        // Имени в файле нет — подпись берётся из адреса, как у остальных.
        assertEquals("1.2.3.4:51820", s.title)
    }

    @Test
    fun `без обязательного поля conf не принимается`() {
        // То же, что проверяет бинарник: иначе сервер попал бы в список, а
        // туннель молча не поднялся.
        assertNull(SubscriptionParser.parseWgConf(
            "[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = $publicB64\n" +
                "Endpoint = 1.2.3.4:1\n"))
        assertNull(SubscriptionParser.parseWgConf(
            "[Interface]\nPrivateKey = $privateB64\nAddress = 10.0.0.2/32\n" +
                "[Peer]\nPublicKey = $publicB64\n"))
        assertNull(SubscriptionParser.parseWgConf("vless://u@a.example:443"))
    }

    @Test
    fun `ссылка wireguard разбирается`() {
        val s = SubscriptionParser.parseLink(
            "wireguard://38GCTbJEvBrai7BT7K8SzCJbD92q35iwl98JRQb_gqI@1.2.3.4:51820" +
                "?publickey=$publicB64&address=10.0.0.2/32&dns=1.1.1.1&mtu=1280" +
                "&keepalive=25&jc=10&jmin=47#Дом"
        )
        assertNotNull(s)
        s!!
        assertEquals("wireguard", s.protocol)
        assertEquals("Дом", s.name)
        assertEquals(51820, s.port)
        // Url-safe алфавит и потерянный паддинг возвращаются на место: иначе
        // ключ не декодируется, а туннель не поднимается без внятной причины.
        assertEquals(privateB64, s.privateKey)
        assertEquals(publicB64, s.publicKey)
        assertEquals("jc=10,jmin=47", s.awg)
    }

    @Test
    fun `два пира на одном адресе не схлопываются в один`() {
        // У wireguard нет ни uuid, ни пароля, поэтому ключ различает их по
        // публичному ключу пира.
        val one = SubscriptionParser.parseWgConf(conf)!!
        val two = one.copy(publicKey = "zxrL/zVlGsR8kjYEg5uS7Krt9XmrgNjliUk6NDvaTEE=")
        assertEquals(2, Subscriptions.addUnique(listOf(one), two)?.size)
    }

    @Test
    fun `подпись не показывает заглушки security и network`() {
        val s = SubscriptionParser.parseWgConf(conf)!!
        assertEquals("wireguard + обфускация", s.subtitle)
        assertEquals("wireguard", s.copy(awg = "").subtitle)
    }

    @Test
    fun `круг profiles-json не теряет полей wireguard`() {
        val s = SubscriptionParser.parseWgConf(conf)!!
        val o = ProfilesJson.serverToJson(s)
        // Имена на диске заморожены: их читают Windows, macOS и iOS.
        for (key in listOf("private_key", "preshared_key", "local_address",
                           "allowed_ips", "wg_dns", "mtu", "keepalive", "awg")) {
            assertTrue("нет ключа $key", o.has(key))
        }
        assertEquals(s, ProfilesJson.serverFromJson(o))
    }

    @Test
    fun `круг хранения на устройстве не теряет полей wireguard`() {
        val s = SubscriptionParser.parseWgConf(conf)!!
        assertEquals(s, Server.fromJson(s.toJson()))
    }

    @Test
    fun `собранный conf читается тем же разбором`() {
        // Файл пишется для бинарника, и проверить его на телефоне нечем.
        // Поэтому сверяем через собственный разбор: писатель и читатель обязаны
        // сходиться, иначе туннель не поднимется без объяснений.
        val s = SubscriptionParser.parseWgConf(conf)!!
        val back = SubscriptionParser.parseWgConf(AwgProcess.buildConf(s))
        assertNotNull(back)
        // Имя в .conf для бинарника не пишется — оно ему не нужно.
        assertEquals(s, back!!.copy(name = s.name))
    }

    @Test
    fun `IPv6-endpoint переживает круг через conf`() {
        val s = SubscriptionParser.parseWgConf(
            "[Interface]\nPrivateKey = $privateB64\nAddress = 10.0.0.2/32\n" +
                "[Peer]\nPublicKey = $publicB64\nEndpoint = [2a01:4f8::1]:51820\n"
        )!!
        assertEquals("2a01:4f8::1", s.address)
        assertEquals(s.address, SubscriptionParser.parseWgConf(AwgProcess.buildConf(s))!!.address)
    }
}
