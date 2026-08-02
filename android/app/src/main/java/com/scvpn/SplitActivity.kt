package com.scvpn

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageView
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * Экран выбора приложений для раздельного туннелирования.
 *
 * Список приложений собирается в фоне: `getInstalledPackages` вместе с иконками
 * на большом устройстве занимает заметное время, и на главном потоке экран
 * открывался бы с задержкой.
 *
 * Выбор сохраняется сразу, но применяется при следующем подключении — список
 * приложений задаётся при подъёме туннеля и потом не меняется (ограничение
 * VpnService, не наше).
 */
class SplitActivity : AppCompatActivity() {

    private lateinit var listView: ListView
    private lateinit var loading: ProgressBar
    private lateinit var search: EditText
    private lateinit var adapter: AppsAdapter

    private var all: List<SplitTunnel.AppEntry> = emptyList()
    private var shown: List<SplitTunnel.AppEntry> = emptyList()
    private val chosen = mutableSetOf<String>()
    private var mode = SplitTunnel.OFF
    private var routeMode = XrayConfig.ROUTE_GLOBAL

    private val ui = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_split)
        title = getString(R.string.split_title)

        listView = findViewById(R.id.apps)
        loading = findViewById(R.id.loading)
        search = findViewById(R.id.search)

        mode = Prefs.splitMode(this)
        routeMode = Prefs.routeMode(this)
        chosen.addAll(Prefs.splitApps(this))

        val auto = findViewById<RadioButton>(R.id.mode_auto)
        val off = findViewById<RadioButton>(R.id.mode_off)
        val exclude = findViewById<RadioButton>(R.id.mode_exclude)
        val include = findViewById<RadioButton>(R.id.mode_include)

        // «Авто» задаётся режимом маршрутизации, остальные три — разбором по
        // приложениям; вместе это один взаимоисключающий выбор.
        when {
            routeMode == XrayConfig.ROUTE_BYPASS_RU && mode == SplitTunnel.OFF -> auto.isChecked = true
            mode == SplitTunnel.EXCLUDE -> exclude.isChecked = true
            mode == SplitTunnel.INCLUDE -> include.isChecked = true
            else -> off.isChecked = true
        }
        auto.setOnClickListener { choose(XrayConfig.ROUTE_BYPASS_RU, SplitTunnel.OFF) }
        off.setOnClickListener { choose(XrayConfig.ROUTE_GLOBAL, SplitTunnel.OFF) }
        exclude.setOnClickListener { choose(XrayConfig.ROUTE_GLOBAL, SplitTunnel.EXCLUDE) }
        include.setOnClickListener { choose(XrayConfig.ROUTE_GLOBAL, SplitTunnel.INCLUDE) }

        adapter = AppsAdapter()
        listView.adapter = adapter
        listView.setOnItemClickListener { _, _, pos, _ -> toggle(shown[pos]) }

        search.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) = applyFilter(s?.toString().orEmpty())
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        })

        choose(routeMode, mode)
        loadApps()
    }

    private fun loadApps() {
        loading.visibility = View.VISIBLE
        Thread {
            val apps = SplitTunnel.installedApps(applicationContext)
            ui.post {
                all = apps
                loading.visibility = View.GONE
                applyFilter(search.text.toString())
            }
        }.start()
    }

    private fun applyFilter(query: String) {
        val q = query.trim().lowercase()
        shown = if (q.isEmpty()) all
        else all.filter { it.label.lowercase().contains(q) || it.packageName.contains(q) }
        adapter.notifyDataSetChanged()
    }

    private fun choose(route: String, split: String) {
        routeMode = route
        mode = split
        Prefs.setRouteMode(this, route)
        Prefs.setSplitMode(this, split)

        // Список приложений нужен только двум вариантам из четырёх.
        val enabled = split != SplitTunnel.OFF
        search.isEnabled = enabled
        listView.isEnabled = enabled
        listView.alpha = if (enabled) 1f else 0.4f
    }

    private fun toggle(app: SplitTunnel.AppEntry) {
        if (mode == SplitTunnel.OFF) return
        if (!chosen.add(app.packageName)) chosen.remove(app.packageName)
        Prefs.setSplitApps(this, chosen)
        adapter.notifyDataSetChanged()
    }

    override fun onBackPressed() {
        if (ScVpnService.isRunning) {
            android.widget.Toast.makeText(
                this, R.string.split_applies_next, android.widget.Toast.LENGTH_LONG
            ).show()
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    private inner class AppsAdapter : BaseAdapter() {
        override fun getCount() = shown.size
        override fun getItem(position: Int) = shown[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val view = convertView ?: layoutInflater.inflate(R.layout.item_app, parent, false)
            val app = shown[position]
            view.findViewById<ImageView>(R.id.icon).setImageDrawable(app.icon)
            view.findViewById<TextView>(R.id.label).text = app.label
            view.findViewById<TextView>(R.id.pkg).text = app.packageName
            view.findViewById<CheckBox>(R.id.checked).isChecked = app.packageName in chosen
            return view
        }
    }
}
