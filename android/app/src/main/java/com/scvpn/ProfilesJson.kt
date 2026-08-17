package com.scvpn

import org.json.JSONArray
import org.json.JSONObject

/**
 * Обмен профилями с десктопными версиями — формат `profiles.json`.
 *
 * Android хранит серверы в SharedPreferences своими именами полей
 * (`alterId`, `publicKey`), а Windows, macOS и iOS — файлом с именами из
 * Python-версии (`alter_id`, `public_key`). Из-за этого профиль нельзя было
 * перенести ни туда, ни обратно: единственным способом оставалось руками
 * пересобрать список ссылок.
 *
 * **Имена ключей заморожены.** Их правка ломает чтение чужих файлов, а
 * пользователь узнает об этом, когда перенос молча потеряет половину полей.
 */
object ProfilesJson {

    /** Один сервер в десктопном виде. */
    fun serverToJson(s: Server): JSONObject = JSONObject().apply {
        put("protocol", s.protocol)
        put("name", s.name)
        put("address", s.address)
        put("port", s.port)
        put("uuid", s.uuid)
        put("password", s.password)
        put("method", s.method)
        put("alter_id", s.alterId)
        put("network", s.network)
        put("security", s.security)
        put("flow", s.flow)
        put("sni", s.sni)
        put("fingerprint", s.fingerprint)
        put("alpn", s.alpn)
        put("public_key", s.publicKey)
        put("short_id", s.shortId)
        put("spider_x", s.spiderX)
        put("allow_insecure", s.allowInsecure)
        put("ws_path", s.wsPath)
        put("ws_host", s.wsHost)
        put("grpc_service", s.grpcService)
        // wireguard/AmneziaWG. Публичный ключ пира уже уехал выше в
        // `public_key` — у Reality это поле значит ровно то же самое.
        put("private_key", s.privateKey)
        put("preshared_key", s.presharedKey)
        put("local_address", s.localAddress)
        put("allowed_ips", s.allowedIPs)
        put("wg_dns", s.wgDns)
        put("mtu", s.mtu)
        put("keepalive", s.keepalive)
        put("awg", s.awg)
    }

    /** Сервер из десктопного вида. Неизвестные поля пропускаются. */
    fun serverFromJson(o: JSONObject, sub: String = ""): Server = Server(
        protocol = o.optString("protocol", "vless"),
        name = o.optString("name"),
        address = o.optString("address"),
        port = o.optInt("port", 443),
        uuid = o.optString("uuid"),
        password = o.optString("password"),
        method = o.optString("method"),
        alterId = o.optInt("alter_id", 0),
        network = o.optString("network", "tcp"),
        security = o.optString("security", "none"),
        flow = o.optString("flow"),
        sni = o.optString("sni"),
        fingerprint = o.optString("fingerprint"),
        alpn = o.optString("alpn"),
        publicKey = o.optString("public_key"),
        shortId = o.optString("short_id"),
        spiderX = o.optString("spider_x", "/"),
        wsPath = o.optString("ws_path", "/"),
        wsHost = o.optString("ws_host"),
        grpcService = o.optString("grpc_service"),
        allowInsecure = o.optBoolean("allow_insecure", false),
        privateKey = o.optString("private_key"),
        presharedKey = o.optString("preshared_key"),
        localAddress = o.optString("local_address"),
        allowedIPs = o.optString("allowed_ips"),
        wgDns = o.optString("wg_dns"),
        mtu = o.optInt("mtu", 0),
        keepalive = o.optInt("keepalive", 0),
        awg = o.optString("awg"),
        sub = sub,
    )

    /**
     * Собрать файл: свои серверы отдельно, серверы подписок — внутри своих
     * подписок, как на десктопе.
     */
    fun export(servers: List<Server>, subs: List<Prefs.Sub>): JSONObject {
        val own = JSONArray()
        servers.filter { it.sub.isBlank() }.forEach { own.put(serverToJson(it)) }

        val subsArray = JSONArray()
        subs.forEach { sub ->
            val theirs = JSONArray()
            servers.filter { it.sub == sub.url }.forEach { theirs.put(serverToJson(it)) }
            subsArray.put(JSONObject().apply {
                put("name", sub.info.title.ifBlank { sub.url })
                put("url", sub.url)
                put("added", sub.added)
                put("updated", sub.info.fetched)
                put("servers", theirs)
                put("info", sub.info.toJson())
            })
        }
        return JSONObject().apply {
            put("servers", own)
            put("subscriptions", subsArray)
        }
    }

    /** Что вычитали из файла. */
    data class Imported(val servers: List<Server>, val subs: List<Prefs.Sub>)

    /**
     * Разобрать файл десктопной версии.
     *
     * Серверы подписок помечаются её ссылкой — иначе первое же обновление
     * посчитало бы их ручными и оставило дубликатами.
     */
    fun import(root: JSONObject): Imported {
        val servers = mutableListOf<Server>()
        val ownArray = root.optJSONArray("servers") ?: JSONArray()
        for (i in 0 until ownArray.length()) {
            servers += serverFromJson(ownArray.getJSONObject(i))
        }

        val subs = mutableListOf<Prefs.Sub>()
        val subsArray = root.optJSONArray("subscriptions") ?: JSONArray()
        for (i in 0 until subsArray.length()) {
            val o = subsArray.getJSONObject(i)
            val url = o.optString("url")
            if (url.isBlank()) continue
            val info = runCatching { SubInfo.fromJson(o.getJSONObject("info")) }
                .getOrDefault(SubInfo())
            subs += Prefs.Sub(url, info, o.optString("added"))
            val theirs = o.optJSONArray("servers") ?: JSONArray()
            for (j in 0 until theirs.length()) {
                servers += serverFromJson(theirs.getJSONObject(j), sub = url)
            }
        }
        return Imported(servers, subs)
    }

    /**
     * Слить импортированное с тем, что уже есть.
     *
     * Дубликаты отсекаются по тому же ключу, что и при добавлении ссылкой:
     * человек переносит профиль поверх непустого списка чаще, чем кажется.
     */
    fun mergeInto(existing: List<Server>, incoming: List<Server>): List<Server> {
        val known = existing.map { it.key() }.toHashSet()
        return existing + incoming.filter { known.add(it.key()) }
    }
}
