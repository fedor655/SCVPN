package com.scvpn

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Хранение серверов и настроек в SharedPreferences (видно в открытом виде). */
object Prefs {
    private const val FILE = "scvpn"
    private const val KEY_SERVERS = "servers"
    private const val KEY_SELECTED = "selected"
    private const val KEY_SUB_URL = "sub_url"          // прежняя единственная подписка
    private const val KEY_SUBS = "subs"                // список подписок: [{url, info, added}]
    private const val KEY_PINGS = "pings"
    private const val KEY_HWID = "hwid"
    private const val KEY_SPLIT_MODE = "split_mode"
    private const val KEY_SPLIT_APPS = "split_apps"
    private const val KEY_ROUTE_MODE = "route_mode"

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun loadServers(ctx: Context): MutableList<Server> {
        val raw = sp(ctx).getString(KEY_SERVERS, "[]") ?: "[]"
        val arr = runCatching { JSONArray(raw) }.getOrDefault(JSONArray())
        return MutableList(arr.length()) { Server.fromJson(arr.getJSONObject(it)) }
    }

    fun saveServers(ctx: Context, servers: List<Server>) {
        val arr = JSONArray()
        servers.forEach { arr.put(it.toJson()) }
        sp(ctx).edit().putString(KEY_SERVERS, arr.toString()).apply()
    }

    fun selectedIndex(ctx: Context): Int = sp(ctx).getInt(KEY_SELECTED, 0)
    fun setSelectedIndex(ctx: Context, i: Int) = sp(ctx).edit().putInt(KEY_SELECTED, i).apply()

    /// Прежняя единственная подписка. Читается только при переезде на список
    /// (см. `subs`) — писать в неё больше некому.
    private fun legacySubUrl(ctx: Context): String = sp(ctx).getString(KEY_SUB_URL, "") ?: ""

    // --- подписки: их может быть несколько, как на десктопе ---

    /**
     * Одна подписка: ссылка, последний ответ панели и когда добавлена.
     */
    data class Sub(val url: String, val info: SubInfo = SubInfo(), val added: String = "") {
        fun toJson(): JSONObject = JSONObject().apply {
            put("url", url); put("info", info.toJson()); put("added", added)
        }

        companion object {
            fun fromJson(o: JSONObject): Sub = Sub(
                url = o.optString("url"),
                info = runCatching { SubInfo.fromJson(o.getJSONObject("info")) }.getOrDefault(SubInfo()),
                added = o.optString("added"),
            )
        }
    }

    /**
     * Список подписок.
     *
     * Первое чтение поднимает старую единственную подписку в список: у людей
     * на руках уже стоят сборки, где она хранилась одной строкой, и терять её
     * при обновлении приложения нельзя.
     */
    fun subs(ctx: Context): MutableList<Sub> {
        val raw = sp(ctx).getString(KEY_SUBS, "") ?: ""
        if (raw.isBlank()) {
            val legacy = legacySubUrl(ctx)
            if (legacy.isBlank()) return mutableListOf()
            val migrated = mutableListOf(Sub(legacy, subInfo(ctx), subAdded(ctx)))
            saveSubs(ctx, migrated)
            return migrated
        }
        val arr = runCatching { JSONArray(raw) }.getOrDefault(JSONArray())
        return MutableList(arr.length()) { Sub.fromJson(arr.getJSONObject(it)) }
    }

    fun saveSubs(ctx: Context, subs: List<Sub>) {
        val arr = JSONArray()
        subs.forEach { arr.put(it.toJson()) }
        sp(ctx).edit()
            .putString(KEY_SUBS, arr.toString())
            // Старый ключ держим в согласии со списком: на него смотрит код,
            // который ещё не перевели, и пустой список обязан его гасить.
            .putString(KEY_SUB_URL, subs.firstOrNull()?.url ?: "")
            .apply()
    }

    /** HWID считается один раз (см. Hwid.kt) и дальше не меняется. */
    fun hwid(ctx: Context): String = sp(ctx).getString(KEY_HWID, "") ?: ""
    fun setHwid(ctx: Context, value: String) = sp(ctx).edit().putString(KEY_HWID, value).apply()

    // --- сведения о подписке (последний успешный ответ панели) ---

    private const val KEY_SUB_INFO = "sub_info"
    private const val KEY_SUB_ADDED = "sub_added"

    /// Сведения прежней единственной подписки — тоже только для переезда.
    fun subInfo(ctx: Context): SubInfo {
        val raw = sp(ctx).getString(KEY_SUB_INFO, "") ?: ""
        if (raw.isBlank()) return SubInfo()
        return runCatching { SubInfo.fromJson(org.json.JSONObject(raw)) }.getOrDefault(SubInfo())
    }

    /// Когда добавили прежнюю единственную подписку — только для переезда.
    fun subAdded(ctx: Context): String = sp(ctx).getString(KEY_SUB_ADDED, "") ?: ""

    // --- раздельное туннелирование ---

    /** «Авто» (обход РФ) или всё через VPN. Разбирается ядром по гео-базам. */
    fun routeMode(ctx: Context): String =
        sp(ctx).getString(KEY_ROUTE_MODE, XrayConfig.ROUTE_GLOBAL) ?: XrayConfig.ROUTE_GLOBAL

    fun setRouteMode(ctx: Context, mode: String) =
        sp(ctx).edit().putString(KEY_ROUTE_MODE, mode).apply()

    fun splitMode(ctx: Context): String =
        sp(ctx).getString(KEY_SPLIT_MODE, SplitTunnel.OFF) ?: SplitTunnel.OFF

    fun setSplitMode(ctx: Context, mode: String) =
        sp(ctx).edit().putString(KEY_SPLIT_MODE, mode).apply()

    fun splitApps(ctx: Context): Set<String> =
        sp(ctx).getStringSet(KEY_SPLIT_APPS, emptySet())?.toSet() ?: emptySet()

    fun setSplitApps(ctx: Context, apps: Set<String>) =
        // Копия обязательна: SharedPreferences не копирует переданный Set,
        // и его последующее изменение молча испортило бы сохранённое значение.
        sp(ctx).edit().putStringSet(KEY_SPLIT_APPS, HashSet(apps)).apply()

    fun selectedServer(ctx: Context): Server? {
        val servers = loadServers(ctx)
        return servers.getOrNull(selectedIndex(ctx)) ?: servers.firstOrNull()
    }

    // --- пинги: key сервера -> задержка в мс (-1 = не отвечает) ---

    fun loadPings(ctx: Context): MutableMap<String, Long> {
        val raw = sp(ctx).getString(KEY_PINGS, "{}") ?: "{}"
        val o = runCatching { org.json.JSONObject(raw) }.getOrNull() ?: return mutableMapOf()
        val out = mutableMapOf<String, Long>()
        o.keys().forEach { out[it] = o.optLong(it, -1) }
        return out
    }

    fun savePings(ctx: Context, pings: Map<String, Long>) {
        val o = org.json.JSONObject()
        pings.forEach { (k, v) -> o.put(k, v) }
        sp(ctx).edit().putString(KEY_PINGS, o.toString()).apply()
    }
}
