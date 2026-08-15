// swift-tools-version:5.10
// Не поднимать до 6.0 в этом проекте: строгая проверка конкурентности Swift 6
// ломает демона, который держит состояние под NSRecursiveLock и намеренно
// шарит его между accept-циклом, читателем stdout и потоком-писателем.
import PackageDescription

let package = Package(
    name: "SCVPN",
    platforms: [.macOS(.v13)],
    targets: [
        // Общая логика: без AppKit, без SwiftUI. Линкуется и в приложение,
        // и в демона, и в оба тестовых таргета.
        .target(name: "SCVPNCore"),

        // Логика демона живёт здесь, а не в исполняемом таргете: SwiftPM не
        // даёт тестовому таргету линковать executable, а без проверок демона
        // весь план бессмыслен.
        .target(name: "SCVPNHelperKit", dependencies: ["SCVPNCore"]),

        // Демон. Отдельный исполняемый файл, а не флаг приложения: он обязан
        // подниматься даже когда с приложением что-то не так, и у него нет ни
        // одной причины загружать графические фреймворки под root.
        .executableTarget(name: "SCVPNHelper", dependencies: ["SCVPNHelperKit"]),

        .executableTarget(name: "SCVPNApp", dependencies: ["SCVPNCore"]),

        .testTarget(name: "SCVPNCoreTests", dependencies: ["SCVPNCore"]),
        .testTarget(name: "SCVPNHelperTests", dependencies: ["SCVPNHelperKit"]),
    ]
)
