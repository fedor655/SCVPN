package com.scvpn

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder

/** Подписка ответила, но серверов не отдала — и объяснила почему. */
class SubscriptionException(message: String) : Exception(message)

/**
 * Парсер ссылок (vless/vmess/trojan/ss) и подписок.
 * Подписка — URL, отдающий список ссылок (обычно в base64).
 * Порт с десктопной версии: каждая функция делает ровно то, что в имени.
 */
object SubscriptionParser {

    private const val USER_AGENT = "v2rayNG/1.9.5"

    /**
     * Параметры обфускации AmneziaWG в именах UAPI — те же, что понимает
     * бинарник (см. `awg/conf.go`).
     *
     * Порядок фиксирован: из него собирается поле `awg`, и при разном порядке
     * один и тот же сервер, добавленный дважды, выглядел бы разным.
     */
    private val AWG_PARAMS = listOf(
        "jc", "jmin", "jmax",
        "s1", "s2", "s3", "s4",
        "h1", "h2", "h3", "h4",
        "i1", "i2", "i3", "i4", "i5",
    )

    /** Порт wireguard по умолчанию — его же ставит wg-quick. */
    private const val WG_PORT = 51820

    fun fetchSubscription(ctx: Context, url: String): List<Server> =
        fetchSubscriptionFull(ctx, url).first

    /** Серверы + сведения подписки (срок, трафик, автообновление). */
    fun fetchSubscriptionFull(ctx: Context, url: String): Pair<List<Server>, SubInfo> {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("User-Agent", USER_AGENT)
            // Идентификатор устройства: без него панели с привязкой к
            // устройствам отдают заглушку вместо серверов (см. Hwid.kt).
            Hwid.headers(ctx).forEach { (k, v) -> setRequestProperty(k, v) }
            connectTimeout = 20000
            readTimeout = 20000
        }
        try {
            conn.inputStream.use { ins ->
                val text = ins.readBytes().toString(Charsets.UTF_8)
                val servers = parseSubscriptionText(text)
                raiseIfPanelStub(servers, conn)
                return servers to SubInfo.fromHeaders(conn)
            }
        } catch (e: java.io.IOException) {
            // Частый случай: домен провайдера подписки заблокирован, а его же
            // VPN-серверы доступны. Получается замкнутый круг — подписку не
            // обновить без VPN, а VPN не включить без серверов. Обычная ошибка
            // сети об этом не говорит, поэтому объясняем прямо.
            throw SubscriptionException(
                "Не удалось связаться с сайтом подписки (${URL(url).host}).\n\n" +
                    "Чаще всего это значит, что домен провайдера заблокирован, — " +
                    "сами VPN-серверы при этом обычно работают.\n\n" +
                    "Подключись к любому уже добавленному серверу и обнови ещё раз. " +
                    "Если серверов нет — добавь один ссылкой vless:// или отсканируй QR."
            )
        }
    }

    /**
     * Отличить заглушку панели от настоящего списка серверов.
     *
     * Панель не возвращает ошибку HTTP: она отдаёт один фиктивный
     * `vless://0000...@0.0.0.0:1`, у которого в имени написана причина. Без этой
     * проверки такая строка молча попадала бы в список серверов — ровно это и
     * выглядело как «сервер App not supported», к которому нельзя подключиться.
     */
    private fun raiseIfPanelStub(servers: List<Server>, conn: HttpURLConnection) {
        if (servers.isEmpty()) return
        val allStubs = servers.all { it.address in listOf("0.0.0.0", "127.0.0.1", "") || it.port <= 1 }
        if (!allStubs) return

        val reason = servers.first().name.trim()
        fun header(name: String) = conn.getHeaderField(name)?.lowercase()

        throw SubscriptionException(
            when {
                header("x-hwid-max-devices-reached") == "true" ->
                    "Достигнут лимит устройств на аккаунте" +
                        (if (reason.isNotBlank()) " ($reason)" else "") + ".\n\n" +
                        "Освободи слот у провайдера подписки и обнови ещё раз."

                header("x-hwid-not-supported") == "true" ->
                    "Панель не приняла идентификатор устройства. " +
                        "Похоже, клиент представился неверно — это чинится в SCVPN."

                else ->
                    "Подписка вернула не список серверов, а сообщение: " +
                        "«${reason.ifBlank { "без пояснения" }}»."
            }
        )
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
                // Однострочная форма wireguard для подписок. Две схемы, потому
                // что панели пишут то одну, то другую, а разбор у них один.
                link.startsWith("wireguard://") || link.startsWith("awg://") -> parseWireguard(link)
                else -> null
            }
        }.getOrNull()
    }

    /**
     * Разбор многострочного `.conf` (wg-quick + расширения AmneziaWG).
     *
     * Это тот самый файл, что отдаёт панель, и ровно этот текст лежит в
     * QR-коде. Поэтому он разбирается **до** разбиения на строки: построчный
     * разбор увидел бы в нём мусор и вернул пустоту.
     *
     * Обязательные поля те же, что проверяет бинарник (`awg/conf.go`): без них
     * сервер попал бы в список, а туннель потом молча не поднялся. `null`
     * значит «это не .conf», и вызывающий пробует остальные виды ссылок.
     */
    fun parseWgConf(text: String): Server? {
        if (!text.contains("[Interface]", ignoreCase = true)) return null

        val s = Server(protocol = "wireguard", port = WG_PORT)
        val obfuscation = mutableMapOf<String, String>()
        var section = ""

        for (raw in text.lines()) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            if (line.startsWith("#") || line.startsWith(";")) {
                // Имя сервера панели кладут комментарием `# Name = ...` —
                // больше его в файле взять неоткуда.
                val comment = line.trimStart('#', ';').trim()
                val eq = comment.indexOf('=')
                if (eq > 0 && comment.substring(0, eq).trim().equals("name", ignoreCase = true)) {
                    s.name = comment.substring(eq + 1).trim()
                }
                continue
            }
            if (line.startsWith("[") && line.endsWith("]")) {
                section = line.substring(1, line.length - 1).trim().lowercase()
                continue
            }
            val eq = line.indexOf('=')
            if (eq < 0) continue
            val key = line.substring(0, eq).trim().lowercase()
            val value = line.substring(eq + 1).trim()
            if (value.isEmpty()) continue

            when (section) {
                "interface" -> when (key) {
                    "privatekey" -> s.privateKey = value
                    "address" -> s.localAddress = joinList(value)
                    "dns" -> s.wgDns = joinList(value)
                    "mtu" -> s.mtu = value.toIntOrNull() ?: 0
                    // ListenPort, Table, PreUp/PostUp и прочее к туннелю в
                    // юзерспейсе отношения не имеют — файл от этого не «кривой».
                    else -> if (key in AWG_PARAMS) obfuscation[key] = value
                }
                "peer" -> when (key) {
                    "publickey" -> s.publicKey = value
                    "presharedkey" -> s.presharedKey = value
                    "endpoint" -> setEndpoint(s, value)
                    "allowedips" -> s.allowedIPs = joinList(value)
                    // «off» — это «не слать», то есть ноль.
                    "persistentkeepalive" -> s.keepalive = value.toIntOrNull() ?: 0
                }
            }
        }

        s.awg = AWG_PARAMS.mapNotNull { p -> obfuscation[p]?.let { "$p=$it" } }.joinToString(",")

        val complete = s.privateKey.isNotBlank() && s.publicKey.isNotBlank() &&
            s.address.isNotBlank() && s.localAddress.isNotBlank()
        return if (complete) s else null
    }

    private fun parseWireguard(link: String): Server {
        val u = URI(link)
        // Регистр имён параметров у панелей гуляет, а смысл один — приводим к
        // нижнему, как это делает и разбор .conf.
        val q = query(u).mapKeys { it.key.lowercase() }
        return Server(protocol = "wireguard").apply {
            privateKey = normalizeKey(u.userInfo ?: "")
            address = u.host ?: ""
            port = if (u.port > 0) u.port else WG_PORT
            name = u.fragment?.let { dec(it) } ?: ""
            publicKey = normalizeKey(q["publickey"] ?: "")
            presharedKey = normalizeKey(q["presharedkey"] ?: "")
            localAddress = joinList(q["address"] ?: "")
            allowedIPs = joinList(q["allowedips"] ?: "")
            wgDns = joinList(q["dns"] ?: "")
            mtu = q["mtu"]?.toIntOrNull() ?: 0
            keepalive = q["keepalive"]?.toIntOrNull() ?: 0
            awg = AWG_PARAMS.mapNotNull { p ->
                q[p]?.takeIf { it.isNotBlank() }?.let { "$p=$it" }
            }.joinToString(",")
        }
    }

    /** Endpoint пира: `host:port`, у IPv6 — `[адрес]:порт`. */
    private fun setEndpoint(s: Server, value: String) {
        val colon = value.lastIndexOf(':')
        if (colon <= 0) return
        // Скобки снимаем: в модели лежит голый адрес, обратно их добавляет
        // сборка .conf (AwgProcess).
        s.address = value.substring(0, colon).trim().trim('[', ']')
        s.port = value.substring(colon + 1).trim().toIntOrNull() ?: WG_PORT
    }

    /** Список через запятую без лишних пробелов и пустых элементов. */
    private fun joinList(value: String): String =
        value.split(",").map { it.trim() }.filter { it.isNotEmpty() }.joinToString(",")

    /**
     * Ключ из ссылки в тот вид, которого ждёт бинарник, — обычный base64.
     *
     * `URLDecoder` здесь применять нельзя, а его следы приходится убирать:
     * плюс он превращает в пробел, а в base64 плюс значащий. Дальше — url-safe
     * алфавит обратно в обычный и паддинг, без которого декодер откажется
     * читать ключ, а туннель не поднимется без внятной причины.
     */
    private fun normalizeKey(raw: String): String {
        val s = raw.trim().replace(' ', '+').replace('-', '+').replace('_', '/')
        if (s.isEmpty()) return ""
        return s + "=".repeat((4 - s.length % 4) % 4)
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
