package com.scvpn

import android.content.Context
import org.json.JSONArray

/** Хранение серверов и настроек в SharedPreferences (видно в открытом виде). */
object Prefs {
    private const val FILE = "scvpn"
    private const val KEY_SERVERS = "servers"
    private const val KEY_SELECTED = "selected"
    private const val KEY_SUB_URL = "sub_url"
    private const val KEY_PINGS = "pings"
    private const val KEY_HWID = "hwid"
    private const val KEY_SPLIT_MODE = "split_mode"
    private const val KEY_SPLIT_APPS = "split_apps"

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

    fun subUrl(ctx: Context): String = sp(ctx).getString(KEY_SUB_URL, "") ?: ""
    fun setSubUrl(ctx: Context, url: String) = sp(ctx).edit().putString(KEY_SUB_URL, url).apply()

    /** HWID считается один раз (см. Hwid.kt) и дальше не меняется. */
    fun hwid(ctx: Context): String = sp(ctx).getString(KEY_HWID, "") ?: ""
    fun setHwid(ctx: Context, value: String) = sp(ctx).edit().putString(KEY_HWID, value).apply()

    // --- сведения о подписке (последний успешный ответ панели) ---

    private const val KEY_SUB_INFO = "sub_info"
    private const val KEY_SUB_ADDED = "sub_added"

    fun subInfo(ctx: Context): SubInfo {
        val raw = sp(ctx).getString(KEY_SUB_INFO, "") ?: ""
        if (raw.isBlank()) return SubInfo()
        return runCatching { SubInfo.fromJson(org.json.JSONObject(raw)) }.getOrDefault(SubInfo())
    }

    fun setSubInfo(ctx: Context, info: SubInfo) =
        sp(ctx).edit().putString(KEY_SUB_INFO, info.toJson().toString()).apply()

    fun subAdded(ctx: Context): String = sp(ctx).getString(KEY_SUB_ADDED, "") ?: ""
    fun setSubAdded(ctx: Context, value: String) =
        sp(ctx).edit().putString(KEY_SUB_ADDED, value).apply()

    // --- раздельное туннелирование ---

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
