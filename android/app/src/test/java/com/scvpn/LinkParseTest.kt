package com.scvpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Разбор ссылок без параметров.
 *
 * Такие ссылки встречаются: панели отдают короткий вид, когда транспорт
 * умолчательный. Десктоп и iOS их берут, поэтому Android обязан тоже — иначе
 * один и тот же сервер добавляется на одной платформе и не добавляется на
 * другой.
 */
class LinkParseTest {

    @Test
    fun `vless без параметров разбирается`() {
        val s = SubscriptionParser.parseLink(
            "vless://aaaaaaaa-1111-2222-3333-444444444444@dup.example.com:443")
        assertNotNull(s)
        assertEquals("dup.example.com", s!!.address)
        assertEquals(443, s.port)
        assertEquals("tcp", s.network)
    }

    @Test
    fun `vless с параметрами разбирается`() {
        val s = SubscriptionParser.parseLink(
            "vless://aaaaaaaa-1111-2222-3333-444444444444@x.example.com:443" +
                "?type=tcp&security=reality&pbk=k&sid=00&sni=ya.ru#Имя")
        assertNotNull(s)
        assertEquals("reality", s!!.security)
        assertEquals("Имя", s.name)
    }
}
