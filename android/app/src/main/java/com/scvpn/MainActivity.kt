package com.scvpn

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
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
import android.widget.PopupMenu
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

/**
 * Единственный экран приложения.
 *
 * Статус берётся из широковещательных сообщений сервиса (см. VpnBus), а не из
 * таймера, — поэтому «Подключение…» держится ровно столько, сколько идёт
 * подъём туннеля, и ошибка видна сразу.
 */
class MainActivity : AppCompatActivity() {

    private val reqVpn = 1

    private lateinit var power: PowerButtonView
    private lateinit var statusText: TextView
    private lateinit var subtitleText: TextView
    private lateinit var modeText: TextView
    private lateinit var list: ListView
    private lateinit var emptyBox: View
    private lateinit var adapter: ServerAdapter

    private lateinit var logStrip: View
    private lateinit var logLine: TextView
    private lateinit var logChevron: ImageView
    private lateinit var logBody: ScrollView
    private lateinit var logText: TextView

    /**
     * Лог развёрнут.
     *
     * Не в настройках: это состояние взгляда, а не приложения — разворачивают
     * лог, чтобы посмотреть здесь и сейчас.
     */
    private var logExpanded = false

    private var servers: MutableList<Server> = mutableListOf()
    private var pings: MutableMap<String, Long> = mutableMapOf()
    private var pinging = false

    private val ui = Handler(Looper.getMainLooper())

    /**
     * Сканер QR. Регистрируется здесь, а не по нажатию кнопки: Android требует
     * регистрировать получателей результата до того, как активность станет
     * видимой. Разрешение на камеру спрашивает сам экран сканирования.
     * Результат не добавляем молча — возвращаем в поле ввода, чтобы было
     * видно, что именно распозналось.
     */
    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        val text = result.contents
        if (!text.isNullOrBlank()) showAddDialog(text.trim())
    }

    /**
     * Выбор файла профилей для импорта.
     *
     * `OpenDocument`, а не `GetContent`: только он даёт постоянный доступ к
     * чужому файлу и показывает нормальный проводник, где лежит выгрузка с
     * компьютера.
     */
    private val importLauncher =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri != null) importProfiles(uri)
        }

    /** Куда сохранить выгрузку. */
    private val exportLauncher =
        registerForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
            if (uri != null) exportProfiles(uri)
        }

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
        statusText = findViewById(R.id.status)
        subtitleText = findViewById(R.id.subtitle)
        modeText = findViewById(R.id.mode)
        list = findViewById(R.id.list)
        emptyBox = findViewById(R.id.empty)

        logStrip = findViewById(R.id.log_strip)
        logLine = findViewById(R.id.log_line)
        logChevron = findViewById(R.id.log_chevron)
        logBody = findViewById(R.id.log_body)
        logText = findViewById(R.id.log_text)
        logStrip.setOnClickListener { toggleLog() }
        logStrip.contentDescription = getString(R.string.log_expand)
        renderLog()

        power.setOnClickListener { onPowerClick() }
        findViewById<ImageButton>(R.id.btn_add).setOnClickListener { showAddDialog() }
        findViewById<ImageButton>(R.id.btn_refresh).setOnClickListener { updateSubscription() }
        findViewById<ImageButton>(R.id.btn_ping).setOnClickListener { pingAll() }
        findViewById<ImageButton>(R.id.btn_more).setOnClickListener { showOverflow(it) }

        adapter = ServerAdapter()
        list.adapter = adapter
        list.setOnItemClickListener { _, _, pos, _ -> selectServer(pos) }
        // Долгое нажатие по серверу — удалить его.
        list.setOnItemLongClickListener { _, _, pos, _ -> showServerActions(pos); true }

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

        // Строки приходят из фоновых потоков — сервиса и колбэка ядра.
        CoreLog.onLine { ui.post { renderLog() } }
        renderLog()
    }

    override fun onStop() {
        super.onStop()
        ui.removeCallbacks(ticker)
        CoreLog.onLine(null)
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

        // Цветом состояния в чёрно-белой теме не различить, поэтому его
        // показывает форма кольца: подключено — толстое сплошное, ошибка —
        // пунктир, простой — тонкое приглушённое. Рисует это сама кнопка,
        // она же растворяет одно состояние в другое.
        power.show(state)

        // Крупная надпись всегда полной яркости: состояние читается словом и
        // кольцом, а притушенный заголовок только размывал бы шкалу.
        statusText.text = when (state) {
            VpnState.CONNECTED -> getString(R.string.state_connected)
            VpnState.CONNECTING -> getString(R.string.state_connecting)
            VpnState.ERROR -> "Не подключилось"
            VpnState.IDLE -> getString(R.string.state_idle)
        }
        power.contentDescription = statusText.text

        // Строка подробностей: при живом подключении — сколько оно держится,
        // в остальных случаях — куда собирались подключаться. Причина отказа
        // вытесняет и то и другое: она и есть та подробность, ради которой
        // строка нужна.
        subtitleText.text = when {
            state == VpnState.ERROR && message.isNotBlank() -> message
            state == VpnState.CONNECTED -> {
                // Имя от сервиса, а не из списка: выбор мог смениться, а
                // туннель остался на прежнем сервере. Новый вид показывал бы
                // здесь один аптайм, но тогда пропадает ровно то, ради чего
                // это имя сюда и добавили — какой сервер держит трафик прямо
                // сейчас. Правда важнее одинаковости, поэтому имя остаётся.
                val name = VpnBus.serverTitle.ifBlank { selected?.title ?: "" }
                val secs = if (VpnBus.since > 0)
                    (SystemClock.elapsedRealtime() - VpnBus.since) / 1000 else 0
                if (name.isBlank()) elapsed(secs) else "$name  ·  ${elapsed(secs)}"
            }
            else -> selected?.title ?: ""
        }

        // Режим — только при живом подключении: в простое он ни о чём не
        // сообщает, потому что ничего ещё не поднято.
        if (state == VpnState.CONNECTED) {
            modeText.setText(modeCaption())
            modeText.visibility = View.VISIBLE
        } else {
            modeText.visibility = View.GONE
        }
    }

    /**
     * Что именно идёт через туннель.
     *
     * Ответ собирается из тех же настроек, по которым туннель и строится
     * (`Prefs.routeMode` + `Prefs.splitMode`), — второго места с этой логикой
     * не заводим. Порядок проверок повторяет экран раздельного
     * туннелирования: «Авто» там — это обход РФ при выключенном разборе по
     * приложениям.
     */
    private fun modeCaption(): Int = when {
        Prefs.splitMode(this) == SplitTunnel.EXCLUDE -> R.string.mode_exclude
        Prefs.splitMode(this) == SplitTunnel.INCLUDE -> R.string.mode_include
        Prefs.routeMode(this) == XrayConfig.ROUTE_BYPASS_RU -> R.string.mode_bypass_ru
        else -> R.string.mode_all
    }

    // ------------------------------------------------------------------
    // Лог ядра
    // ------------------------------------------------------------------

    /**
     * Полоса лога.
     *
     * Свёрнута до одной строки: лог читают ради последнего сообщения, а не
     * ради истории. Строку обрезает сама разметка — с начала, потому что у
     * сообщения ядра важен хвост.
     */
    private fun renderLog() {
        logLine.text = CoreLog.last() ?: getString(R.string.log_empty)
        if (!logExpanded) return
        logText.text = CoreLog.snapshot().joinToString("\n")
        // Развёрнутый лог тоже читают снизу — держим хвост в виду.
        logBody.post { logBody.fullScroll(View.FOCUS_DOWN) }
    }

    private fun toggleLog() {
        logExpanded = !logExpanded
        logBody.visibility = if (logExpanded) View.VISIBLE else View.GONE
        logChevron.animate()
            .rotation(if (logExpanded) 90f else 0f)
            .setDuration(PowerButtonView.STATE_MS)
            .start()
        logStrip.contentDescription =
            getString(if (logExpanded) R.string.log_collapse else R.string.log_expand)
        renderLog()
    }

    private fun elapsed(totalSeconds: Long): String {
        val h = totalSeconds / 3600
        val m = (totalSeconds % 3600) / 60
        val s = totalSeconds % 60
        // Локаль задаётся явно: иначе счётчик времени в части локалей
        // печатается их цифрами и превращается в кашу.
        return if (h > 0) String.format(java.util.Locale.ROOT, "%d:%02d:%02d", h, m, s)
               else String.format(java.util.Locale.ROOT, "%02d:%02d", m, s)
    }

    // ------------------------------------------------------------------
    // Серверы
    // ------------------------------------------------------------------
    private fun reloadServers() {
        servers = Prefs.loadServers(this)
        adapter.notifyDataSetChanged()
        emptyBox.visibility = if (servers.isEmpty()) View.VISIBLE else View.GONE
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

    /**
     * Одно поле на оба случая: ссылку сервера узнаёт парсер, всё остальное с
     * http(s) считается подпиской. Спрашивать «это ссылка или подписка?»
     * значило бы перекладывать на человека то, что видно из самой строки.
     */
    private fun showAddDialog(prefill: String = "") {
        // Поля у всех окон поверх главного одни: разные заметны, когда окна
        // открывают подряд.
        val pad = resources.getDimensionPixelSize(R.dimen.sheet_pad_h)
        val input = EditText(this).apply {
            hint = getString(R.string.dlg_add_hint)
            setSingleLine(false)
            maxLines = 4
            setText(prefill)
            setSelection(prefill.length)
        }
        val box = FrameLayout(this).apply {
            setPadding(pad, resources.getDimensionPixelSize(R.dimen.sheet_gap), pad, 0)
            addView(input, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.dlg_add_title)
            .setView(box)
            .setPositiveButton(R.string.action_add) { _, _ -> addSomething(input.text.toString()) }
            .setNeutralButton(R.string.dlg_add_scan) { _, _ -> launchScanner() }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun addSomething(raw: String) {
        val text = raw.trim()
        if (text.isEmpty()) return
        when {
            SubscriptionParser.parseLink(text) != null -> addLink(text)
            text.startsWith("http://") || text.startsWith("https://") -> addSubscription(text)
            else -> toast("Это не похоже ни на ссылку сервера, ни на URL подписки")
        }
    }

    private fun launchScanner() {
        scanLauncher.launch(
            ScanOptions().apply {
                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                setPrompt(getString(R.string.scan_prompt))
                setBeepEnabled(false)
                setCaptureActivity(PortraitCaptureActivity::class.java)
                // Ориентацию задаёт манифест нашего экрана; библиотеке своё
                // мнение навязывать не даём, иначе она зафиксирует текущую.
                setOrientationLocked(false)
            }
        )
    }

    private fun addLink(text: String) {
        val s = SubscriptionParser.parseLink(text.trim())
        if (s == null) { toast("Не распознал ссылку"); return }
        val merged = Subscriptions.addUnique(servers, s)
        if (merged == null) { toast("Такой сервер уже есть: ${s.title}"); return }
        servers = merged.toMutableList()
        Prefs.saveServers(this, servers)
        reloadServers()
        toast("Добавлен: ${s.title}")
    }

    private fun addSubscription(url: String) {
        val u = url.trim()
        if (u.isEmpty()) { toast("Введи URL подписки"); return }
        // В список подписка попадает только после успешной загрузки — это
        // делает fetchSub. Иначе опечатка в адресе оставляла в списке мёртвую
        // запись навсегда, и удалять её приходилось руками.
        fetchSub(u)
    }

    /** Обновить все подписки по очереди. */
    private fun updateSubscription() {
        val subs = Prefs.subs(this)
        if (subs.isEmpty()) { toast("Сначала добавь подписку"); return }
        subs.forEach { fetchSub(it.url) }
    }

    // ------------------------------------------------------------------
    // Удаление
    // ------------------------------------------------------------------
    private fun showOverflow(anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add(0, 1, 0, getString(R.string.menu_subscription))
            menu.add(0, 2, 1, getString(R.string.menu_split))
            menu.add(0, 3, 2, getString(R.string.delete_subscription))
            menu.add(0, 4, 3, getString(R.string.export_profiles))
            menu.add(0, 5, 4, getString(R.string.import_profiles))
            setOnMenuItemClickListener {
                when (it.itemId) {
                    1 -> showSubscriptionInfo()
                    2 -> startActivity(Intent(this@MainActivity, SplitActivity::class.java))
                    3 -> confirmDeleteSubscription()
                    4 -> exportLauncher.launch("profiles.json")
                    5 -> importLauncher.launch(arrayOf("application/json", "text/plain", "*/*"))
                }
                true
            }
            show()
        }
    }

    /** Экран подписки: сколько потрачено, до какого числа, ссылка и QR. */
    /**
     * Экран подписки. Если их несколько — сперва спрашиваем, какую показать:
     * раньше открывалась всегда первая, и до остальных было не добраться.
     */
    private fun showSubscriptionInfo() {
        val subs = Prefs.subs(this)
        when (subs.size) {
            0 -> toast(getString(R.string.no_subscription))
            1 -> showSubscriptionInfo(subs[0])
            else -> AlertDialog.Builder(this)
                .setTitle(R.string.menu_subscription)
                .setItems(subs.map { it.info.title.ifBlank { it.url } }.toTypedArray()) { _, which ->
                    showSubscriptionInfo(subs[which])
                }
                .setNegativeButton(R.string.cancel, null)
                .show()
        }
    }

    private fun showSubscriptionInfo(sub: Prefs.Sub) {
        val url = sub.url
        val info = sub.info
        val view = layoutInflater.inflate(R.layout.dialog_subscription, null)

        view.findViewById<TextView>(R.id.sub_account).text = info.account
        view.findViewById<TextView>(R.id.sub_url).text = url

        view.findViewById<TextView>(R.id.sub_announce).apply {
            if (info.announce.isBlank()) visibility = View.GONE
            else { text = info.announce; visibility = View.VISIBLE }
        }

        val left = info.daysLeft
        val expires = if (info.expire <= 0) "бессрочно"
        else info.expiresText + when {
            left == null -> ""
            left < 0 -> "  ·  истекла"
            else -> "  ·  осталось $left дн."
        }
        val traffic = if (info.unlimited)
            "${SubInfo.humanBytes(info.used)}  (безлимит)"
        else
            "${SubInfo.humanBytes(info.used)} из ${SubInfo.humanBytes(info.total)}"

        view.findViewById<TextView>(R.id.sub_stats).text = buildString {
            appendLine("Потрачено:  $traffic")
            appendLine("Отдано / принято:  ${SubInfo.humanBytes(info.upload)} / ${SubInfo.humanBytes(info.download)}")
            appendLine("Действует до:  $expires")
            appendLine("Автообновление:  ${SubInfo.humanInterval(info.updateInterval)}")
            appendLine("Серверов:  ${servers.count { it.sub == url }}")
            if (sub.added.isNotBlank()) appendLine("Добавлена:  ${sub.added}")
            if (info.fetched.isNotBlank()) append("Данные обновлены:  ${info.fetched}")
        }

        view.findViewById<ImageView>(R.id.sub_qr).apply {
            val bmp = Qr.encode(url, 220 * resources.displayMetrics.density.toInt().coerceAtLeast(1))
            if (bmp != null) setImageBitmap(bmp) else visibility = View.GONE
        }

        AlertDialog.Builder(this)
            .setTitle(info.title.ifBlank { getString(R.string.menu_subscription) })
            .setView(view)
            .setPositiveButton(R.string.close, null)
            .setNeutralButton(R.string.copy_link) { _, _ ->
                val cb = getSystemService(ClipboardManager::class.java)
                cb.setPrimaryClip(ClipData.newPlainText("SCVPN", url))
                toast("Ссылка скопирована")
            }
            .setNegativeButton(R.string.share) { _, _ ->
                startActivity(Intent.createChooser(
                    Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, url)
                    }, getString(R.string.share)
                ))
            }
            .show()
    }

    private fun confirmDeleteSubscription() {
        val subs = Prefs.subs(this)
        if (subs.isEmpty()) { toast("Подписки нет"); return }
        if (subs.size == 1) { confirmDeleteSubscription(subs[0].url); return }
        // Подписок несколько — сначала спрашиваем, какую.
        AlertDialog.Builder(this)
            .setTitle(R.string.delete_subscription)
            .setItems(subs.map { it.info.title.ifBlank { it.url } }.toTypedArray()) { _, which ->
                confirmDeleteSubscription(subs[which].url)
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun confirmDeleteSubscription(url: String) {
        AlertDialog.Builder(this)
            .setTitle(R.string.delete_subscription)
            .setMessage("Удалить подписку и все её серверы?")
            .setPositiveButton(R.string.delete) { _, _ ->
                val subs = Prefs.subs(this).filterNot { it.url == url }
                Prefs.saveSubs(this, subs)

                // Уходят только серверы этой подписки: добавленные вручную и
                // чужие остаются на месте.
                val gone = servers.filter { it.sub == url }
                servers = Subscriptions.remove(servers, url).toMutableList()
                Prefs.saveServers(this, servers)
                gone.forEach { pings.remove(it.key()) }
                Prefs.savePings(this, pings)
                Prefs.setSelectedIndex(this, 0)
                reloadServers()
                toast("Подписка удалена")
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    /**
     * Выгрузить профили в формате десктопной версии.
     *
     * Формат общий с Windows, macOS и iOS — файл можно перенести на любую из
     * них и обратно.
     */
    private fun exportProfiles(uri: android.net.Uri) {
        val root = ProfilesJson.export(servers, Prefs.subs(this))
        val ok = runCatching {
            contentResolver.openOutputStream(uri)?.use { it.write(root.toString(2).toByteArray()) }
        }.isSuccess
        toast(if (ok) "Профили сохранены" else "Не удалось сохранить файл")
    }

    private fun importProfiles(uri: android.net.Uri) {
        val parsed = runCatching {
            val text = contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                ?: error("файл не читается")
            ProfilesJson.import(org.json.JSONObject(text))
        }
        parsed.onFailure { toast("Это не файл профилей SCVPN"); return }

        val imported = parsed.getOrThrow()
        if (imported.servers.isEmpty() && imported.subs.isEmpty()) {
            toast("В файле нет ни серверов, ни подписок"); return
        }

        // Добавляем, а не заменяем: человек переносит профиль поверх непустого
        // списка чаще, чем начисто, и потерять при этом свои серверы обидно.
        val before = servers.size
        servers = ProfilesJson.mergeInto(servers, imported.servers).toMutableList()
        Prefs.saveServers(this, servers)

        val subs = Prefs.subs(this)
        val known = subs.map { it.url }.toHashSet()
        imported.subs.forEach { if (known.add(it.url)) subs.add(it) }
        Prefs.saveSubs(this, subs)

        reloadServers()
        toast("Добавлено серверов: ${servers.size - before}")
    }

    private fun showServerActions(pos: Int) {
        val s = servers.getOrNull(pos) ?: return
        // Сервер подписки вернётся при первом же обновлении, поэтому удалять
        // его поштучно бессмысленно — вместо кнопки-обманки объясняем, откуда
        // он взялся. Так же ведёт себя iOS-версия.
        if (s.sub.isNotBlank()) {
            AlertDialog.Builder(this)
                .setTitle(s.title)
                .setMessage("Сервер из подписки — удаляется вместе с ней.")
                .setPositiveButton(R.string.close, null)
                .show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle(s.title)
            .setItems(arrayOf(getString(R.string.delete_server))) { _, _ -> deleteServer(pos) }
            .show()
    }

    private fun deleteServer(pos: Int) {
        val removed = servers.getOrNull(pos) ?: return
        // Удаление из списка туннель не гасит: конфиг уже у ядра. Без этой
        // строки человек думал бы, что убрал сервер вместе с подключением.
        val active = VpnBus.current == VpnState.CONNECTED &&
            VpnBus.serverTitle == removed.title
        servers.removeAt(pos)
        Prefs.saveServers(this, servers)
        if (Prefs.selectedIndex(this) >= servers.size) {
            Prefs.setSelectedIndex(this, (servers.size - 1).coerceAtLeast(0))
        }
        reloadServers()
        if (active) {
            toast("Туннель ещё работает через «${removed.title}» — отключись, чтобы прекратить")
        } else {
            toast("Удалён: ${removed.title}")
        }
    }

    private fun fetchSub(url: String) {
        toast("Обновляю подписку…")
        Thread {
            val result = runCatching {
                SubscriptionParser.fetchSubscriptionFull(applicationContext, url)
            }
            ui.post {
                result.onSuccess { (fetched, info) ->
                    if (fetched.isEmpty()) { toast("В подписке не нашлось серверов"); return@post }

                    // Серверы этой подписки заменяются целиком, чужие остаются:
                    // раньше обновление сносило и вставленные вручную ссылки.
                    val selectedKey = Prefs.selectedServer(this)?.key()
                    servers = Subscriptions.merge(servers, fetched, url).toMutableList()
                    Prefs.saveServers(this, servers)

                    // Пинги этой подписки сбрасываем: за тем же именем может
                    // стоять уже другой сервер, и старое число врало бы.
                    fetched.forEach { pings.remove(it.key()) }
                    Prefs.savePings(this, pings)

                    val subs = Prefs.subs(this)
                    val at = subs.indexOfFirst { it.url == url }
                    val added = subs.getOrNull(at)?.added?.ifBlank { SubInfo.nowStamp() }
                        ?: SubInfo.nowStamp()
                    val updated = Prefs.Sub(url, info, added)
                    if (at >= 0) subs[at] = updated else subs.add(updated)
                    Prefs.saveSubs(this, subs)

                    // Выбор сохраняем по ключу: индекс после пересборки списка
                    // указывал бы на чужой сервер.
                    Prefs.setSelectedIndex(this, Subscriptions.selectionAfterMerge(servers, selectedKey))
                    reloadServers()
                    toast("Подписка: ${fetched.size} серверов")
                }.onFailure { e ->
                    // Отказ панели (лимит устройств и т.п.) — это не сбой сети,
                    // а то, что нужно прочитать и исправить у провайдера.
                    if (e is SubscriptionException) {
                        AlertDialog.Builder(this)
                            .setTitle("Подписка")
                            .setMessage(e.message)
                            .setPositiveButton("Понятно", null)
                            .show()
                    } else {
                        toast("Ошибка подписки: ${e.message}")
                    }
                }
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
            val selected = position == Prefs.selectedIndex(this@MainActivity)

            // Выбор показывается маркером слева и полной яркостью имени —
            // рамка того же белого на чёрном почти не читалась.
            view.findViewById<View>(R.id.marker).visibility =
                if (selected) View.VISIBLE else View.INVISIBLE

            // Под последней строкой линии нет: там и так край списка.
            view.findViewById<View>(R.id.divider).visibility =
                if (position == servers.size - 1) View.INVISIBLE else View.VISIBLE

            view.findViewById<TextView>(R.id.name).apply {
                text = s.title
                setTextColor(ContextCompat.getColor(
                    context, if (selected) R.color.text else R.color.text_dim))
            }
            // Адрес яркость не теряет и у невыбранной строки: иначе он уходит
            // под порог читаемости.
            view.findViewById<TextView>(R.id.sub).text = s.subtitle

            val pingView = view.findViewById<TextView>(R.id.ping)
            when (val ms = pings[s.key()]) {
                // До замера — прочерк, а не пустота: пустое место справа
                // выглядит так, будто строку не дорисовали.
                null -> {
                    pingView.text = "—"
                    pingView.setTextColor(ContextCompat.getColor(context, R.color.muted))
                }
                -1L -> {
                    // «Плохо» в монохроме показываем словом, а не цветом.
                    pingView.text = "нет ответа"
                    pingView.setTextColor(ContextCompat.getColor(context, R.color.muted))
                }
                else -> {
                    pingView.text = "$ms мс"
                    val c = when {
                        ms < 200 -> R.color.text      // чем медленнее, тем тусклее
                        ms < 500 -> R.color.text_dim
                        else -> R.color.muted
                    }
                    pingView.setTextColor(ContextCompat.getColor(context, c))
                }
            }

            view.isActivated = selected
            return view
        }
    }
}
