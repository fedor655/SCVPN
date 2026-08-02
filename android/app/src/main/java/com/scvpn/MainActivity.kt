package com.scvpn

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.GradientDrawable
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

/**
 * Единственный экран приложения.
 *
 * Статус берётся из широковещательных сообщений сервиса (см. VpnBus), а не из
 * таймера, — поэтому «Подключение…» держится ровно столько, сколько идёт
 * подъём туннеля, и ошибка видна сразу.
 */
class MainActivity : AppCompatActivity() {

    private val reqVpn = 1

    private lateinit var power: FrameLayout
    private lateinit var powerIcon: ImageView
    private lateinit var statusText: TextView
    private lateinit var subtitleText: TextView
    private lateinit var list: ListView
    private lateinit var emptyText: TextView
    private lateinit var adapter: ServerAdapter

    private var servers: MutableList<Server> = mutableListOf()
    private var pings: MutableMap<String, Long> = mutableMapOf()
    private var pinging = false

    private val ui = Handler(Looper.getMainLooper())

    /** Тикает раз в секунду, пока подключены, — обновляет время сессии. */
    private val ticker = object : Runnable {
        override fun run() {
            if (VpnBus.current == VpnState.CONNECTED) {
                renderState(VpnState.CONNECTED, "")
                ui.postDelayed(this, 1000)
            }
        }
    }

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = runCatching {
                VpnState.valueOf(intent.getStringExtra(VpnBus.EXTRA_STATE) ?: "IDLE")
            }.getOrDefault(VpnState.IDLE)
            val message = intent.getStringExtra(VpnBus.EXTRA_MESSAGE).orEmpty()
            renderState(state, message)
            if (state == VpnState.ERROR && message.isNotBlank()) toast(message)
            ui.removeCallbacks(ticker)
            if (state == VpnState.CONNECTED) ui.post(ticker)
        }
    }

    // ------------------------------------------------------------------
    // Жизненный цикл
    // ------------------------------------------------------------------
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        power = findViewById(R.id.power)
        powerIcon = findViewById(R.id.power_icon)
        statusText = findViewById(R.id.status)
        subtitleText = findViewById(R.id.subtitle)
        list = findViewById(R.id.list)
        emptyText = findViewById(R.id.empty)

        power.setOnClickListener { onPowerClick() }
        findViewById<ImageButton>(R.id.btn_add).setOnClickListener { showAddDialog() }
        findViewById<ImageButton>(R.id.btn_refresh).setOnClickListener { updateSubscription() }
        findViewById<ImageButton>(R.id.btn_ping).setOnClickListener { pingAll() }

        adapter = ServerAdapter()
        list.adapter = adapter
        list.setOnItemClickListener { _, _, pos, _ -> selectServer(pos) }

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
        }

        pings = Prefs.loadPings(this)
        reloadServers()
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter(VpnBus.ACTION_STATE)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(stateReceiver, filter)
        }
        // Сервис мог подняться или упасть, пока экрана не было.
        val live = if (ScVpnService.isRunning) VpnState.CONNECTED else VpnState.IDLE
        renderState(if (VpnBus.current == VpnState.CONNECTING) VpnState.CONNECTING else live, "")
        if (live == VpnState.CONNECTED) ui.post(ticker)
    }

    override fun onStop() {
        super.onStop()
        ui.removeCallbacks(ticker)
        runCatching { unregisterReceiver(stateReceiver) }
    }

    // ------------------------------------------------------------------
    // Подключение
    // ------------------------------------------------------------------
    private fun onPowerClick() {
        when (VpnBus.current) {
            VpnState.CONNECTING -> return                    // уже в процессе — не мешаем
            VpnState.CONNECTED -> {
                startService(Intent(this, ScVpnService::class.java).setAction(ScVpnService.ACTION_STOP))
            }
            else -> {
                if (servers.isEmpty()) { toast("Сначала добавь сервер"); return }
                val prep = VpnService.prepare(this)
                if (prep != null) startActivityForResult(prep, reqVpn) else startVpn()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == reqVpn) {
            if (resultCode == Activity.RESULT_OK) startVpn()
            else toast("Без разрешения на VPN подключиться нельзя")
        }
    }

    private fun startVpn() {
        renderState(VpnState.CONNECTING, "")
        val i = Intent(this, ScVpnService::class.java).setAction(ScVpnService.ACTION_START)
        ContextCompat.startForegroundService(this, i)
    }

    // ------------------------------------------------------------------
    // Отрисовка состояния
    // ------------------------------------------------------------------
    private fun renderState(state: VpnState, message: String) {
        val selected = servers.getOrNull(Prefs.selectedIndex(this))

        val accent = when (state) {
            VpnState.CONNECTED -> R.color.teal
            VpnState.CONNECTING -> R.color.blue
            VpnState.ERROR -> R.color.red
            VpnState.IDLE -> R.color.text_dim
        }
        val color = ContextCompat.getColor(this, accent)

        (power.background.mutate() as? GradientDrawable)?.setStroke(dp(3), color)
        powerIcon.setColorFilter(color)
        statusText.setTextColor(color)

        statusText.text = when (state) {
            VpnState.CONNECTED -> getString(R.string.state_connected)
            VpnState.CONNECTING -> getString(R.string.state_connecting)
            VpnState.ERROR -> "Ошибка"
            VpnState.IDLE -> getString(R.string.state_idle)
        }

        subtitleText.text = when {
            state == VpnState.ERROR && message.isNotBlank() -> message
            state == VpnState.CONNECTED -> {
                val name = selected?.title ?: ""
                val secs = if (VpnBus.since > 0)
                    (SystemClock.elapsedRealtime() - VpnBus.since) / 1000 else 0
                if (name.isBlank()) elapsed(secs) else "$name  ·  ${elapsed(secs)}"
            }
            else -> selected?.title ?: ""
        }
    }

    private fun elapsed(totalSeconds: Long): String {
        val h = totalSeconds / 3600
        val m = (totalSeconds % 3600) / 60
        val s = totalSeconds % 60
        return if (h > 0) String.format("%d:%02d:%02d", h, m, s) else String.format("%02d:%02d", m, s)
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    // ------------------------------------------------------------------
    // Серверы
    // ------------------------------------------------------------------
    private fun reloadServers() {
        servers = Prefs.loadServers(this)
        adapter.notifyDataSetChanged()
        emptyText.visibility = if (servers.isEmpty()) View.VISIBLE else View.GONE
        if (servers.isNotEmpty()) {
            val sel = Prefs.selectedIndex(this).coerceIn(0, servers.size - 1)
            Prefs.setSelectedIndex(this, sel)
            list.setItemChecked(sel, true)
        }
        renderState(VpnBus.current, "")
    }

    private fun selectServer(pos: Int) {
        Prefs.setSelectedIndex(this, pos)
        list.setItemChecked(pos, true)
        adapter.notifyDataSetChanged()
        renderState(VpnBus.current, "")
        if (VpnBus.current == VpnState.CONNECTED) {
            toast("Сервер сменится при следующем подключении")
        }
    }

    private fun showAddDialog() {
        val pad = dp(20)
        val input = EditText(this).apply {
            hint = getString(R.string.dlg_add_hint)
            setSingleLine(false)
            maxLines = 4
        }
        val box = FrameLayout(this).apply {
            setPadding(pad, dp(8), pad, 0)
            addView(input, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.dlg_add_title)
            .setView(box)
            .setPositiveButton(R.string.dlg_add_link) { _, _ -> addLink(input.text.toString()) }
            .setNeutralButton(R.string.dlg_add_sub) { _, _ -> addSubscription(input.text.toString()) }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun addLink(text: String) {
        val s = SubscriptionParser.parseLink(text.trim())
        if (s == null) { toast("Не распознал ссылку"); return }
        servers.add(s)
        Prefs.saveServers(this, servers)
        reloadServers()
        toast("Добавлен: ${s.title}")
    }

    private fun addSubscription(url: String) {
        val u = url.trim()
        if (u.isEmpty()) { toast("Введи URL подписки"); return }
        Prefs.setSubUrl(this, u)
        fetchSub(u)
    }

    private fun updateSubscription() {
        val url = Prefs.subUrl(this)
        if (url.isEmpty()) { toast("Сначала добавь подписку"); return }
        fetchSub(url)
    }

    private fun fetchSub(url: String) {
        toast("Обновляю подписку…")
        Thread {
            val result = runCatching { SubscriptionParser.fetchSubscription(url) }
            ui.post {
                result.onSuccess { fetched ->
                    if (fetched.isEmpty()) { toast("В подписке не нашлось серверов"); return@post }
                    // Пинги переносим по ключу — сервер тот же, мерить заново незачем.
                    servers = fetched.toMutableList()
                    Prefs.saveServers(this, servers)
                    Prefs.setSelectedIndex(this, 0)
                    reloadServers()
                    toast("Подписка: ${fetched.size} серверов")
                }.onFailure { toast("Ошибка подписки: ${it.message}") }
            }
        }.start()
    }

    // ------------------------------------------------------------------
    // Пинг
    // ------------------------------------------------------------------
    private fun pingAll() {
        if (pinging) return
        if (servers.isEmpty()) { toast("Нет серверов"); return }
        if (ScVpnService.isRunning) { toast("Отключись, чтобы померить пинг"); return }

        pinging = true
        toast("Меряю задержку…")
        val snapshot = servers.toList()
        Thread {
            for (s in snapshot) {
                val ms = XrayCore.pingServer(applicationContext, s)
                ui.post {
                    pings[s.key()] = ms
                    adapter.notifyDataSetChanged()
                }
            }
            ui.post {
                pinging = false
                // Отпечаток мог смениться на рабочий — сохраняем вместе с пингами.
                Prefs.saveServers(this, servers)
                Prefs.savePings(this, pings)
                toast("Готово")
            }
        }.start()
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    // ------------------------------------------------------------------
    // Список
    // ------------------------------------------------------------------
    private inner class ServerAdapter : ArrayAdapter<Server>(
        this, R.layout.item_server
    ) {
        override fun getCount() = servers.size
        override fun getItem(position: Int) = servers[position]

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val view = convertView ?: layoutInflater.inflate(R.layout.item_server, parent, false)
            val s = servers[position]

            view.findViewById<TextView>(R.id.name).text = s.title
            view.findViewById<TextView>(R.id.sub).text = s.subtitle

            val pingView = view.findViewById<TextView>(R.id.ping)
            when (val ms = pings[s.key()]) {
                null -> { pingView.text = ""; }
                -1L -> {
                    pingView.text = "нет"
                    pingView.setTextColor(ContextCompat.getColor(context, R.color.red))
                }
                else -> {
                    pingView.text = "$ms мс"
                    val c = when {
                        ms < 200 -> R.color.teal
                        ms < 500 -> R.color.text
                        else -> R.color.red
                    }
                    pingView.setTextColor(ContextCompat.getColor(context, c))
                }
            }

            view.isActivated = position == Prefs.selectedIndex(this@MainActivity)
            return view
        }
    }
}
