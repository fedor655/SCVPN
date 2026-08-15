// swift-tools-version:5.10
// Версия не поднимается до 6.0 по той же причине, что и в macOS-пакете:
// строгая проверка конкурентности Swift 6 ломает код, который намеренно шарит
// состояние между потоками.
import PackageDescription

let package = Package(
    name: "SCVPNCore",
    // Общий код трёх платформ: macOS-приложение с демоном, iOS-приложение и
    // его расширение туннеля. Всё платформенное внутри разделено `#if os()`,
    // а не двумя деревьями файлов: иначе парсеры разъезжаются молча.
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SCVPNCore", targets: ["SCVPNCore"]),
    ],
    targets: [
        .target(name: "SCVPNCore"),
        .testTarget(name: "SCVPNCoreTests", dependencies: ["SCVPNCore"]),
    ]
)
