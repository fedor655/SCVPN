import SCVPNCore
import SwiftUI

/// Точка входа приложения.
///
/// Файл называется `App.swift`, а не `main.swift`, намеренно: SwiftPM в
/// исполняемом таргете считает `main.swift` точкой входа сам, и атрибут
/// `@main` рядом с ним не компилируется.
///
/// Запускать это только собранным бандлом (`./build.sh && open dist/SCVPN.app`).
/// Из `swift run` `Bundle.main` укажет на `.build`, `Info.plist` не подхватится,
/// и приложение получит не ту activation policy и не увидит
/// `NSCameraUsageDescription`.
@main
struct SCVPNApplication: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // Без этого SwiftUI отодвигает содержимое вниз от «безопасной
                // зоны» скрытой полосы заголовка, и шапка уезжает под светофор:
                // кнопки окна оказываются выше надписи, хотя должны стоять с
                // ней на одной линии. Прямой аналог WA_ContentsMarginsRespects‑
                // SafeArea=False, который Qt-версия ставит в двух местах.
                .ignoresSafeArea(.all, edges: .top)
                // Размеры из Python-версии: 420×700 при минимуме 360×540.
                .frame(minWidth: 360, idealWidth: 420,
                       minHeight: 540, idealHeight: 700)
                .background(Color.scvpnBG)
                // Доступ к NSWindow: убрать полосу заголовка мало, светофор
                // надо ещё и опустить, а AppKit возвращает его на место при
                // каждой перекладке.
                .background(WindowChrome().frame(width: 0, height: 0))
        }
        // Даёт titlebarAppearsTransparent и fullSizeContentView разом.
        .windowStyle(.hiddenTitleBar)
    }
}

/// Каркас главного окна.
///
/// Наполнение — Задача 6.2; здесь пока только шапка и фон, на которых
/// проверяется само оформление: своя полоса заголовка, опущенный светофор,
/// перетаскивание за шапку.
struct RootView: View {
    var body: some View {
        VStack(spacing: 0) {
            HeaderView(onPing: {}, onAdd: {}, onMenu: {})
            Divider().overlay(Color.scvpnStroke)
            Spacer(minLength: 0)
            BrandmarkView(side: 96, color: nil)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.scvpnBG)
    }
}
