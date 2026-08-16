import SCVPNCore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var importing = false
    /// Файл готовится при открытии экрана: ShareLink требует ссылку заранее,
    /// а не в момент нажатия.
    @State private var exportURL: URL?

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

                Section("Профили") {
                    if let file = exportURL {
                        ShareLink(item: file) { Text("Сохранить в файл") }
                    }
                    Button("Загрузить из файла") { importing = true }
                    Text("Формат общий с версиями для Windows, macOS и Android — "
                         + "файл переносится между ними.")
                        .font(.scvpnUI(12))
                        .foregroundStyle(Color.scvpnDim)
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
            .onAppear { exportURL = model.exportFile() }
            // Диалог перекрывает главный экран, поэтому его alert не виден:
            // сообщение об импорте показываем здесь же, иначе загрузка файла
            // выглядит как «ничего не произошло».
            .alert(item: $model.alert) { box in
                Alert(title: Text(box.title), message: Text(box.text),
                      dismissButton: .default(Text("Понятно")))
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.json, .plainText]) { result in
                if case .success(let url) = result { model.importProfiles(from: url) }
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
