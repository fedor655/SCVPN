// swift-tools-version:5.10
// Не поднимать до 6.0 в этом проекте: строгая проверка конкурентности Swift 6
// ломает демона, который держит состояние под NSRecursiveLock и намеренно
// шарит его между accept-циклом, читателем stdout и потоком-писателем.
import PackageDescription

let package = Package(
    name: "SCVPN",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Общая логика: без AppKit, без SwiftUI. Переехала в отдельный пакет,
        // потому что тот же код линкуется в iOS-приложение и в расширение
        // туннеля, а копия — это гарантированное расхождение.
        .package(path: "../../core-swift"),
    ],
    targets: [
        // Логика демона живёт здесь, а не в исполняемом таргете: SwiftPM не
        // даёт тестовому таргету линковать executable, а без проверок демона
        // весь план бессмыслен.
        .target(name: "SCVPNHelperKit", dependencies: [
            .product(name: "SCVPNCore", package: "core-swift"),
        ]),

        // Демон. Отдельный исполняемый файл, а не флаг приложения: он обязан
        // подниматься даже когда с приложением что-то не так, и у него нет ни
        // одной причины загружать графические фреймворки под root.
        .executableTarget(name: "SCVPNHelper", dependencies: ["SCVPNHelperKit"]),

        .executableTarget(name: "SCVPNApp", dependencies: [
            .product(name: "SCVPNCore", package: "core-swift"),
        ]),

        .testTarget(name: "SCVPNHelperTests", dependencies: ["SCVPNHelperKit"]),
    ]
)
