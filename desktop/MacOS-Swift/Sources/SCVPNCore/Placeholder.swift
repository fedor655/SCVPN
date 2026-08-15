/// Маркер сборки. Существует затем, чтобы каркас пакета проверялся тем же
/// способом, что и всё остальное, — прогоном `swift test`, а не взглядом.
public enum SCVPNCore {
    public static let buildMarker = "scvpn-core"
}
