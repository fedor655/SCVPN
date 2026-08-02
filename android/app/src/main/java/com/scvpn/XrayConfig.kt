package com.scvpn

import org.json.JSONArray
import org.json.JSONObject

/**
 * Сборка конфига Xray для Android.
 * Отличие от десктопа: один SOCKS-инбаунд на 127.0.0.1 (в него ходит hev-мост),
 * а приватные сети обходим явными CIDR (без geoip-файлов — чтобы ничего не качать).
 */
object XrayConfig {

    const val SOCKS_PORT = 10808

    // Режимы маршрутизации — те же, что на десктопе.
    const val ROUTE_GLOBAL = "global"
    const val ROUTE_BYPASS_RU = "bypass_ru"

    private val PRIVATE_CIDRS = listOf(
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "127.0.0.0/8", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"
    )

    // Что в режиме «Авто» идёт мимо VPN. Список повторяет десктопный.
    private val RU_DOMAINS = listOf(
        "geosite:category-ru", "geosite:yandex", "geosite:vk", "geosite:mailru"
    )

    fun build(
        server: Server,
        socksPort: Int = SOCKS_PORT,
        logLevel: String = "warning",
        routeMode: String = ROUTE_GLOBAL,
    ): String {
        val cfg = JSONObject()
        cfg.put("log", JSONObject().put("loglevel", logLevel))

        // --- inbound: SOCKS на 127.0.0.1 ---
        val sniffing = JSONObject()
            .put("enabled", true)
            .put("destOverride", JSONArray(listOf("http", "tls", "quic")))
        val socksIn = JSONObject()
            .put("tag", "socks-in")
            .put("listen", "127.0.0.1")
            .put("port", socksPort)
            .put("protocol", "socks")
            .put("settings", JSONObject().put("udp", true).put("auth", "noauth"))
            .put("sniffing", sniffing)
        cfg.put("inbounds", JSONArray(listOf(socksIn)))

        // --- outbounds: proxy / direct / block ---
        val outbounds = JSONArray()
        outbounds.put(buildOutbound(server))
        outbounds.put(JSONObject().put("tag", "direct").put("protocol", "freedom").put("settings", JSONObject()))
        outbounds.put(JSONObject().put("tag", "block").put("protocol", "blackhole").put("settings", JSONObject()))
        cfg.put("outbounds", outbounds)

        // --- routing: приватные сети напрямую, остальное в proxy ---
        val rules = JSONArray()
        rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("ip", JSONArray(PRIVATE_CIDRS)))

        if (routeMode == ROUTE_BYPASS_RU) {
            // Российские домены и IP — мимо VPN. Работает по гео-базам,
            // которые GeoAssets кладёт рядом с ядром.
            rules.put(JSONObject().put("type", "field").put("outboundTag", "direct")
                .put("domain", JSONArray(RU_DOMAINS)))
            rules.put(JSONObject().put("type", "field").put("outboundTag", "direct")
                .put("ip", JSONArray(listOf("geoip:ru"))))
        }

        rules.put(JSONObject().put("type", "field").put("outboundTag", "proxy").put("network", "tcp,udp"))
        cfg.put("routing", JSONObject().put("domainStrategy", "IPIfNonMatch").put("rules", rules))

        // --- dns ---
        val dnsServers = JSONArray()
        if (routeMode == ROUTE_BYPASS_RU) {
            // Российские домены резолвим российским DNS и напрямую, иначе
            // ответы приходили бы с зарубежных адресов и правило по IP не срабатывало.
            dnsServers.put(JSONObject().put("address", "77.88.8.8")
                .put("domains", JSONArray(RU_DOMAINS)))
        }
        dnsServers.put("https://1.1.1.1/dns-query")
        dnsServers.put("8.8.8.8")
        cfg.put("dns", JSONObject().put("servers", dnsServers).put("queryStrategy", "UseIP"))

        return cfg.toString()
    }

    /**
     * Мини-конфиг для замера задержки: только один outbound, без инбаундов.
     * Именно такой формат ждёт `Libv2ray.measureOutboundDelay`.
     */
    fun buildForPing(server: Server): String {
        val cfg = JSONObject()
        cfg.put("log", JSONObject().put("loglevel", "none"))
        cfg.put("outbounds", JSONArray().put(buildOutbound(server)))
        return cfg.toString()
    }

    private fun buildOutbound(s: Server): JSONObject {
        val out = JSONObject().put("tag", "proxy").put("protocol", s.protocol)

        when (s.protocol) {
            "vless" -> {
                val user = JSONObject().put("id", s.uuid).put("encryption", "none")
                if (s.flow.isNotBlank()) user.put("flow", s.flow)
                val vnext = JSONObject().put("address", s.address).put("port", s.port)
                    .put("users", JSONArray().put(user))
                out.put("settings", JSONObject().put("vnext", JSONArray().put(vnext)))
            }
            "vmess" -> {
                val user = JSONObject().put("id", s.uuid).put("alterId", s.alterId).put("security", "auto")
                val vnext = JSONObject().put("address", s.address).put("port", s.port)
                    .put("users", JSONArray().put(user))
                out.put("settings", JSONObject().put("vnext", JSONArray().put(vnext)))
            }
            "trojan" -> {
                val srv = JSONObject().put("address", s.address).put("port", s.port).put("password", s.password)
                out.put("settings", JSONObject().put("servers", JSONArray().put(srv)))
            }
            "shadowsocks" -> {
                val srv = JSONObject().put("address", s.address).put("port", s.port)
                    .put("method", s.method).put("password", s.password)
                out.put("settings", JSONObject().put("servers", JSONArray().put(srv)))
            }
        }

        out.put("streamSettings", buildStream(s))
        return out
    }

    private fun buildStream(s: Server): JSONObject {
        val ss = JSONObject().put("network", s.network)
        val fp = sanitizeFingerprint(s.fingerprint)

        when (s.security) {
            "reality" -> {
                ss.put("security", "reality")
                ss.put("realitySettings", JSONObject()
                    .put("serverName", s.sni)
                    .put("fingerprint", fp)
                    .put("publicKey", s.publicKey)
                    .put("shortId", s.shortId)
                    .put("spiderX", s.spiderX.ifBlank { "/" }))
            }
            "tls" -> {
                val tls = JSONObject()
                    .put("serverName", s.sni.ifBlank { s.address })
                    .put("allowInsecure", s.allowInsecure)
                    .put("fingerprint", fp)
                if (s.alpn.isNotBlank()) tls.put("alpn", JSONArray(s.alpn.split(",").map { it.trim() }))
                ss.put("security", "tls").put("tlsSettings", tls)
            }
            else -> ss.put("security", "none")
        }

        when (s.network) {
            "ws" -> {
                val ws = JSONObject().put("path", s.wsPath.ifBlank { "/" })
                val host = s.wsHost.ifBlank { s.sni }
                if (host.isNotBlank()) ws.put("headers", JSONObject().put("Host", host))
                ss.put("wsSettings", ws)
            }
            "grpc" -> ss.put("grpcSettings", JSONObject().put("serviceName", s.grpcService))
            "http" -> {
                val h = JSONObject().put("path", s.wsPath.ifBlank { "/" })
                if (s.wsHost.isNotBlank()) h.put("host", JSONArray().put(s.wsHost))
                ss.put("httpSettings", h)
            }
        }
        return ss
    }
}
