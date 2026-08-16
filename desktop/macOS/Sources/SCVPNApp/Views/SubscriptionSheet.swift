import AppKit
import SCVPNCore
import SwiftUI

/// Подписки: срок, трафик, автообновление, ссылка и QR для переноса.
///
/// Цифры показываем те, что прислала панель, и ничего не додумываем. Чего в
/// заголовках нет — того и нет: даты активации там не бывает, поэтому стоит
/// дата, когда подписку добавили в приложение, и подписана она именно так.
struct SubscriptionSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.subscriptions.isEmpty {
                Text("Подписок пока нет.\nДобавь URL подписки кнопкой  +")
                    .font(.substatus)
                    .foregroundStyle(Color.scvpnDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(model.subscriptions.enumerated()), id: \.offset) { i, sub in
                            card(sub, index: i)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 460)
            }

            HStack {
                Button("Обновить все") { refreshAll() }
                    .disabled(busy || model.subscriptions.isEmpty)
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(Style.sheetPadding)
        .frame(width: Style.sheetWidth)
        .background(Color.scvpnSurface)
    }

    private func card(_ sub: SCVPNCore.Subscription, index: Int) -> some View {
        let info = sub.info
        return VStack(alignment: .leading, spacing: 8) {
            Text(info.title.isEmpty ? (sub.name.isEmpty ? "Подписка" : sub.name) : info.title)
                .font(.scvpnUI(14, weight: .bold))
                .foregroundStyle(Color.scvpnText)
            if !info.account.isEmpty {
                Text(info.account)
                    .font(.scvpnUI(11))
                    .foregroundStyle(Color.scvpnDim)
            }
            if !info.announce.isEmpty {
                Text(info.announce)
                    .font(.scvpnUI(11))
                    .foregroundStyle(Color.scvpnText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row("Серверов", "\(sub.servers.count)")
            row("Трафик", info.unlimited
                ? "\(humanBytes(info.used)) — безлимит"
                : "\(humanBytes(info.used)) из \(humanBytes(info.total))")
            if !info.unlimited { trafficBar(info.usedRatio) }
            row("Действует до", expiry(info))
            row("Автообновление", humanInterval(info.updateInterval))
            row("Обновлено", info.fetched.isEmpty ? "—" : info.fetched)
            if info.deviceLimitReached {
                Text("Достигнут лимит устройств на аккаунте.")
                    .font(.scvpnUI(11))
                    .foregroundStyle(Color.scvpnText)
            }

            linkBlock(sub)

            HStack {
                Button("Обновить") { refresh(index) }.disabled(busy)
                Button("Удалить") { model.removeSubscription(at: index) }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Style.boxCorner).fill(Color.scvpnBG))
        .overlay(RoundedRectangle(cornerRadius: Style.boxCorner)
                .stroke(Color.scvpnStroke, lineWidth: Style.stroke))
    }

    private func linkBlock(_ sub: SCVPNCore.Subscription) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ссылка подписки")
                    .font(.section)
                    .tracking(Style.sectionTracking)
                    .foregroundStyle(Color.scvpnDim)
                Text(sub.url)
                    .font(.scvpnMono(10))
                    .foregroundStyle(Color.scvpnDim)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sub.url, forType: .string)
                }
                if !sub.info.supportURL.isEmpty, let url = URL(string: sub.info.supportURL) {
                    Link("Поддержка", destination: url).font(.scvpnUI(11))
                }
            }
            Spacer(minLength: 0)
            if let qr = qrImage(sub.url, side: 120) {
                VStack(spacing: 4) {
                    Image(nsImage: qr)
                        .interpolation(.none)   // модули QR не размывать
                        .resizable()
                        .frame(width: 110, height: 110)
                        .background(Color.white)
                    Text("Наведи камерой,\nчтобы перенести на телефон")
                        .font(.scvpnUI(9))
                        .foregroundStyle(Color.scvpnDim)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.scvpnUI(11)).foregroundStyle(Color.scvpnDim)
            Spacer()
            Text(value).font(.scvpnUI(11)).foregroundStyle(Color.scvpnText)
        }
    }

    private func trafficBar(_ ratio: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.scvpnStroke)
                Capsule().fill(Color.scvpnText)
                    .frame(width: max(2, geo.size.width * ratio))
            }
        }
        .frame(height: 4)
    }

    private func expiry(_ info: SubscriptionInfo) -> String {
        guard let at = info.expiresAt else { return "бессрочно" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        guard let days = info.daysLeft else { return f.string(from: at) }
        return days >= 0 ? "\(f.string(from: at)) — \(days) дн." : "истекла \(f.string(from: at))"
    }

    private func refresh(_ index: Int) {
        busy = true
        Task { await model.refreshSubscription(at: index); busy = false }
    }

    private func refreshAll() {
        busy = true
        Task { await model.refreshAllSubscriptions(); busy = false }
    }
}
