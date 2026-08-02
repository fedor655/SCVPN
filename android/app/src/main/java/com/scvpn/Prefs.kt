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
