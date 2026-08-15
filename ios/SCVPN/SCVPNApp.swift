import SCVPNCore
import SwiftUI

@main
struct SCVPNApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(model)
                // Тема одна — тёмная, как на macOS и Android. Светлой нет
                // намеренно: палитра сверяется между платформами проверкой.
                .preferredColorScheme(.dark)
        }
    }
}
