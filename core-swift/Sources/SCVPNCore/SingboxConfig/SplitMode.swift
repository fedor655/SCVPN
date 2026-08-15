/// Режимы раздельного туннелирования (split tunneling).
///
/// Строковые значения — часть замороженного протокола сокета и формата
/// `settings.json`. Переименование любого из них молча сломает и то, и другое.
public enum SplitMode: String, Sendable {
    /// Все приложения через VPN.
    case off
    /// Все через VPN, кроме выбранных.
    case exclude
    /// Только выбранные через VPN.
    case include
}

/// Сетевой стек sing-box.
///
/// `gvisor` — свой стек в пространстве пользователя, самый предсказуемый на
/// darwin; `system` быстрее, но опирается на хостовый стек; `mixed` — system
/// для TCP и gvisor для UDP.
public enum Stack: String, Sendable {
    case gvisor
    case system
    case mixed
}
