import SCVPNCore
import SwiftUI

/// Раздельное туннелирование.
///
/// Здесь же живёт и режим маршрутизации: это один и тот же вопрос «что идёт в
/// туннель», и двумя меню он только путал. «Авто» задаётся режимом
/// маршрутизации, остальные три — режимом разбора по приложениям.
struct SplitTunnelSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var choice: Choice = .off
    @State private var apps: [String] = []
    @State private var manual = ""

    enum Choice: String, CaseIterable, Identifiable {
        case auto, off, exclude, include
        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto:    return "Авто — российские сайты напрямую, остальное через VPN"
            case .off:     return "Всё через VPN"
            case .exclude: return "Всё через VPN, кроме выбранных приложений"
            case .include: return "Только выбранные приложения через VPN"
            }
        }

        var picksApps: Bool { self == .exclude || self == .include }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Choice.allCases) { option in
                Button {
                    choice = option
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(choice == option ? Color.scvpnText : Color.scvpnDim)
                        Text(option.title)
                            .font(.scvpnUI(12))
                            .foregroundStyle(Color.scvpnText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }

            Text("""
                Разбор по приложениям работает в режиме «TUN — весь трафик»:
                системный прокси приложения не различает.
                """)
                .font(.scvpnUI(11))
                .foregroundStyle(Color.scvpnDim)
                .fixedSize(horizontal: false, vertical: true)

            if choice.picksApps {
                appPicker
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 430)
        .background(Color.scvpnSurface)
        .onAppear(perform: load)
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ПРИЛОЖЕНИЯ")
                .font(.section)
                .tracking(1.5)
                .foregroundStyle(Color.scvpnDim)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // Запущенные — чтобы не вспоминать имена, плюс уже
                    // выбранные: они могли быть закрыты, и потерять их из-за
                    // этого нельзя.
                    ForEach(candidates, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { apps.contains(name) },
                            set: { on in
                                if on { if !apps.contains(name) { apps.append(name) } }
                                else { apps.removeAll { $0 == name } }
                            })) {
                            Text(name).font(.scvpnUI(12))
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.scvpnBG))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.scvpnStroke, lineWidth: 1))

            HStack(spacing: 6) {
                TextField(RunningApps.manualHint, text: $manual)
                    .textFieldStyle(.roundedBorder)
                    .font(.scvpnUI(12))
                Button("Добавить") { addManual() }
                    .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var candidates: [String] {
        let running = RunningApps.runningApps()
        let extra = apps.filter { !running.contains($0) }
        return (running + extra).sorted { $0.lowercased() < $1.lowercased() }
    }

    private func addManual() {
        let name = RunningApps.normalizeAppName(manual)
        guard !name.isEmpty, !apps.contains(name) else { return }
        apps.append(name)
        manual = ""
    }

    private func load() {
        apps = model.settings["split_apps"]?.stringArray ?? []
        let route = model.settings["route_mode"]?.stringValue ?? "global"
        let mode = SplitMode(rawValue: model.settings["split_mode"]?.stringValue ?? "off") ?? .off
        if route == RouteMode.bypassRU.rawValue && mode == .off {
            choice = .auto
        } else {
            switch mode {
            case .exclude: choice = .exclude
            case .include: choice = .include
            case .off:     choice = .off
            }
        }
    }

    private func save() {
        // «Авто» — это режим маршрутизации, а не разбор по приложениям:
        // сохранить его как split_mode значило бы поднять туннель не тем,
        // чем просили.
        switch choice {
        case .auto:
            model.set("route_mode", .string(RouteMode.bypassRU.rawValue))
            model.set("split_mode", .string(SplitMode.off.rawValue))
        case .off:
            model.set("route_mode", .string(RouteMode.global.rawValue))
            model.set("split_mode", .string(SplitMode.off.rawValue))
        case .exclude, .include:
            model.set("route_mode", .string(RouteMode.global.rawValue))
            model.set("split_mode", .string(choice == .exclude ? SplitMode.exclude.rawValue
                                                               : SplitMode.include.rawValue))
        }
        model.set("split_apps", .array(apps.map { .string($0) }))
        dismiss()
    }
}
