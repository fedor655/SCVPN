import Foundation

public enum SCVPNHelperKit {
    public static let buildMarker = "scvpn-helper-kit"
}

// Заглушки Фазы 1: настоящие приезжают в Задачах 2.3 и 2.12. Стоят здесь
// затем, чтобы `swift build` собирал все пять таргетов уже сейчас — каркас,
// который не линкуется, каркасом не является.
public struct HelperEnv {
    public static func fromEnvironment() -> HelperEnv { HelperEnv() }
}

public func daemonMain(_ env: HelperEnv) -> Never {
    FileHandle.standardError.write(Data("[helper] заглушка Фазы 1\n".utf8))
    exit(1)
}
