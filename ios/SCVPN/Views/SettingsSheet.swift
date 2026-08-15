import SCVPNCore
import SwiftUI

/// Настройки. Только то, что на iOS действительно работает.
///
/// Чего здесь намеренно нет: режима системного прокси (на iOS его не бывает),
/// выбора приложений для раздельного туннелирования (только через MDM),
/// обновления ядра (оно вшито в сборку) и режима «Обход РФ» — он держится на
/// гео-базах, а они не помещаются в лимит памяти расширения. Пункт, который
/// ничего не делает, хуже отсутствующего.
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let fingerprints = ["auto"] + fallbackFingerprints

    var body: some View {
        NavigationStack {
            Form {
                Section("TLS-отпечаток") {
                    Picker("Отпечаток", selection: fingerprintBinding) {
                        ForEach(fingerprints, id: \.self) { fp in
                            Text(fp == "auto" ? "Подбирать сам" : fp).tag(fp)
                        }
                    }
                    if !XrayBridge.available {
                        Text("Автоподбор требует ядра Xray — в этой сборке его нет, "
                             + "выбери отпечаток вручную.")
                            .font(.scvpnUI(12))
                            .foregroundStyle(Color.scvpnDim)
                    }
                }

                Section("Подписки") {
                    HStack {
                        Text("User-Agent")
                        Spacer()
                        TextField(defaultUserAgent, text: userAgentBinding)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(Color.scvpnDim)
                    }
                }

                Section("Ядро") {
                    LabeledContent("Xray", value: XrayBridge.available ? XrayBridge.version
                                                                        : "нет в сборке")
                        .font(.scvpnUI(12))
                }

                Section("Устройство") {
                    LabeledContent("HWID", value: deviceID())
                        .font(.scvpnMono(11))
                        .textSelection(.enabled)
                }

                Section {
                    Text("Маршрутизация: весь трафик через VPN. Раздельные режимы "
                         + "требуют гео-баз, которые не помещаются в лимит памяти "
                         + "расширения туннеля.")
                        .font(.scvpnUI(12))
                        .foregroundStyle(Color.scvpnDim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.scvpnBG)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }

    private var fingerprintBinding: Binding<String> {
        Binding(get: { model.settings["tls_fingerprint"]?.stringValue ?? "auto" },
                set: { model.set("tls_fingerprint", .string($0)) })
    }

    private var userAgentBinding: Binding<String> {
        Binding(get: { model.settings["user_agent"]?.stringValue ?? "" },
                set: { model.set("user_agent", .string($0)) })
    }
}
