package com.scvpn

import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder

/**
 * Парсер ссылок (vless/vmess/trojan/ss) и подписок.
 * Подписка — URL, отдающий список ссылок (обычно в base64).
 * Порт с десктопной версии: каждая функция делает ровно то, что в имени.
 */
object SubscriptionParser {

    private const val USER_AGENT = "v2rayNG/1.9.5"

    fun fetchSubscription(url: String): List<Server> {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("User-Agent", USER_AGENT)
            connectTimeout = 20000
            readTimeout = 20000
        }
        conn.inputStream.use { ins ->
            val text = ins.readBytes().toString(Charsets.UTF_8)
            return parseSubscriptionText(text)
        }
    }

    fun parseSubscriptionText(text: String): List<Server> {
        val candidates = mutableListOf(text.trim())
        runCatching { b64decode(text) }.getOrNull()?.let { candidates.add(it) }
        var best = emptyList<Server>()
        for (cand in candidates) {
            val servers = cand.lines().mapNotNull { parseLink(it) }
            if (servers.size > best.size) best = servers
        }
        return best
    }

    fun parseLink(raw: String): Server? {
        val link = raw.trim()
        if (link.isEmpty()) return null
        return runCatching {
            when {
                link.startsWith("vless://") -> parseVless(link)
                link.startsWith("vmess://") -> parseVmess(link)
                link.startsWith("trojan://") -> parseTrojan(link)
                link.startsWith("ss://") -> parseSs(link)
                else -> null
            }
        }.getOrNull()
    }

    // ---- base64 (url-safe и без паддинга тоже) ----
    private fun b64decode(data: String): String {
        var s = data.trim().replace("\n", "").replace("\r", "").replace("-", "+").replace("_", "/")
        val pad = (4 - s.length % 4) % 4
        s += "=".repeat(pad)
        return String(Base64.decode(s, Base64.DEFAULT), Charsets.UTF_8)
    }

    private fun dec(s: String): String = runCatching { URLDecoder.decode(s, "UTF-8") }.getOrDefault(s)

    private fun query(uri: URI): Map<String, String> {
        val q = uri.rawQuery ?: return emptyMap()
        return q.split("&").mapNotNull {
            val i = it.indexOf('='); if (i < 0) null else dec(it.substring(0, i)) to dec(it.substring(i + 1))
        }.toMap()
    }

    private fun parseVless(link: String): Server {
        val u = URI(link)
        val q = query(u)
        return Server(protocol = "vless").apply {
            uuid = dec(u.userInfo ?: "")
            address = u.host ?: ""
            port = if (u.port > 0) u.port else 443
            name = u.fragment?.let { dec(it) } ?: ""
            network = q["type"] ?: "tcp"
            security = q["security"] ?: "none"
            flow = q["flow"] ?: ""
            sni = q["sni"] ?: q["peer"] ?: ""
            fingerprint = q["fp"] ?: ""
            alpn = q["alpn"] ?: ""
            publicKey = q["pbk"] ?: ""
            shortId = q["sid"] ?: ""
            spiderX = q["spx"] ?: "/"
            wsPath = dec(q["path"] ?: "/")
            wsHost = q["host"] ?: ""
            grpcService = q["serviceName"] ?: ""
            allowInsecure = q["allowInsecure"] in listOf("1", "true")
        }
    }

    private fun parseTrojan(link: String): Server {
        val u = URI(link)
        val q = query(u)
        return Server(protocol = "trojan").apply {
            password = dec(u.userInfo ?: "")
            address = u.host ?: ""
            port = if (u.port > 0) u.port else 443
            name = u.fragment?.let { dec(it) } ?: ""
            network = q["type"] ?: "tcp"
            security = q["security"] ?: "tls"
            sni = q["sni"] ?: q["peer"] ?: ""
            fingerprint = q["fp"] ?: ""
            alpn = q["alpn"] ?: ""
            wsPath = dec(q["path"] ?: "/")
            wsHost = q["host"] ?: ""
            grpcService = q["serviceName"] ?: ""
            allowInsecure = q["allowInsecure"] in listOf("1", "true")
        }
    }

    private fun parseVmess(link: String): Server {
        val json = JSONObject(b64decode(link.removePrefix("vmess://")))
        return Server(protocol = "vmess").apply {
            name = json.optString("ps")
            address = json.optString("add")
            port = json.optString("port", "443").toIntOrNull() ?: 443
            uuid = json.optString("id")
            alterId = json.optString("aid", "0").toIntOrNull() ?: 0
            network = json.optString("net", "tcp")
            security = json.optString("tls").ifBlank { "none" }
            sni = json.optString("sni").ifBlank { json.optString("host") }
            fingerprint = json.optString("fp")
            alpn = json.optString("alpn")
            wsPath = json.optString("path", "/").ifBlank { "/" }
            wsHost = json.optString("host")
            if (network == "grpc") grpcService = json.optString("path")
        }
    }

    private fun parseSs(link: String): Server {
        var body = link.removePrefix("ss://")
        val s = Server(protocol = "shadowsocks")
        val hashIdx = body.indexOf('#')
        if (hashIdx >= 0) {
            s.name = dec(body.substring(hashIdx + 1))
            body = body.substring(0, hashIdx)
        }
        val methodPass: String
        val hostPart: String
        if (body.contains('@')) {
            val at = body.lastIndexOf('@')
            val userinfo = body.substring(0, at)
            hostPart = body.substring(at + 1)
            methodPass = runCatching { b64decode(userinfo) }.getOrDefault(dec(userinfo))
        } else {
            val decoded = b64decode(body)
            val at = decoded.lastIndexOf('@')
            methodPass = decoded.substring(0, at)
            hostPart = decoded.substring(at + 1)
        }
        val colon = methodPass.indexOf(':')
        s.method = methodPass.substring(0, colon)
        s.password = methodPass.substring(colon + 1)
        val hc = hostPart.lastIndexOf(':')
        s.address = hostPart.substring(0, hc)
        s.port = hostPart.substring(hc + 1).toIntOrNull() ?: 8388
        return s
    }
}
