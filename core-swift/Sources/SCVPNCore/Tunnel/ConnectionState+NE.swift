#if os(iOS)
import NetworkExtension

extension ConnectionState {
    /// Статус от системы — единственный источник правды о туннеле.
    ///
    /// Своего перечисления состояний на iOS нет и заводить его нельзя:
    /// `ConnectionState` уже нарисован macOS-версией и уже проверен. А
    /// `.tunStuck` тут не появляется никогда — на iOS туннель снимает сама
    /// система, «просили снять, а он стоит» бывает только с демоном и sing-box.
    public init(_ s: NEVPNStatus) {
        switch s {
        case .connected: self = .connected
        case .connecting, .reasserting: self = .connecting
        // «Отключаемся» отдельным состоянием не заводим: экран показывает то
        // же, что при простое, а лишний случай пришлось бы рисовать на всех
        // платформах ради полусекунды.
        case .disconnecting, .disconnected: self = .idle
        case .invalid: self = .error
        @unknown default: self = .idle
        }
    }
}
#endif
