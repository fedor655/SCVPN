import SCVPNCore
import SwiftUI

/// Меню «⋯».
///
/// Состав дословно по таблице в `desktop/MacOS/README.md`. Маршрутизация
/// целиком живёт в «Раздельном туннелировании» — это один и тот же вопрос «что
/// идёт в туннель», и двумя меню он только путал.
struct MainMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            Picker("Способ подключения", selection: setting("vpn_mode", "proxy")) {
                Text("Системный прокси").tag("proxy")
                Text("TUN — весь трафик (нужен админ)").tag("tun")
            }

            Picker("Отпечаток TLS", selection: setting("tls_fingerprint", "auto")) {
                Text("Авто — подобрать").tag("auto")
                ForEach(fallbackFingerprints, id: \.self) { Text($0).tag($0) }
            }

            // Сетевой стек TUN — тот самый винт, который приходится крутить,
            // когда туннель ведёт себя странно на конкретной сети.
            Picker("Сетевой стек TUN", selection: setting("tun_stack", "gvisor")) {
                Text("gvisor — самый предсказуемый").tag("gvisor")
                Text("system — быстрее").tag("system")
                Text("mixed — TCP системный, UDP gvisor").tag("mixed")
            }

            Divider()

            Toggle("Включать системный прокси", isOn: flag("system_proxy", true))
                // В TUN-режиме системный прокси не при делах: трафик забирает
                // utun целиком. Оставить переключатель живым значило бы
                // обещать действие, которого не будет.
                .disabled(model.mode == .tun)
            Toggle("Блокировать рекламу", isOn: flag("block_ads", false))

            Divider()

            Button("Раздельное туннелирование…") { model.sheet = .splitTunnel }
            Button("Подписки…") { model.sheet = .subscriptions }
            Button("Измерить пинг", action: model.pingAll)
            Button("Скачать ядро Xray") { model.downloadCore() }
            Button("Скачать компоненты TUN") { model.downloadTun() }

            // Показываем, только когда есть что удалять: пункт «удалить» над
            // пустым местом — обещание действия, которое ничего не сделает.
            if model.tunPresent {
                Button("Удалить компоненты TUN…") { model.removeTun() }
            }
            if model.helperInstalled {
                Button("Удалить системный компонент…") { model.removeHelper() }
            }

            Divider()

            Toggle("Показывать лог ядра", isOn: Binding(
                get: { model.showLog },
                set: { model.showLog = $0; model.set("show_log", .bool($0)) }))
        }
    }

    /// Привязка к строковой настройке: чтение из словаря, запись на диск.
    private func setting(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(
            get: { model.settings[key]?.stringValue ?? fallback },
            set: { model.set(key, .string($0)) }
        )
    }

    private func flag(_ key: String, _ fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { model.settings[key]?.boolValue ?? fallback },
            set: { model.set(key, .bool($0)) }
        )
    }
}
