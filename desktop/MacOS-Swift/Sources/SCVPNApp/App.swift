import SwiftUI

/// Точка входа приложения.
///
/// Файл называется `App.swift`, а не `main.swift`, намеренно: SwiftPM в
/// исполняемом таргете считает `main.swift` точкой входа сам, и атрибут
/// `@main` рядом с ним не компилируется.
///
/// Запускать это только собранным бандлом (`./build.sh && open dist/SCVPN.app`).
/// Из `swift run` `Bundle.main` укажет на .build, `Info.plist` не подхватится,
/// и приложение получит не ту activation policy и не увидит
/// `NSCameraUsageDescription`.
@main
struct SCVPNApplication: App {
    var body: some Scene {
        WindowGroup {
            // Каркас Фазы 1. Настоящее окно — Задача 6.2.
            Color.black
                .frame(minWidth: 380, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
