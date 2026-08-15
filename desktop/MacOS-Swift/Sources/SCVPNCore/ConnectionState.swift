import Foundation

/// Состояние экрана подключения.
public enum ConnectionState: String, Sendable, CaseIterable {
    case idle
    case connecting
    case connected
    case error
    /// Просили отключиться, а туннель остался поднятым.
    ///
    /// Отдельное состояние, а не `error`: ошибка подключения и «отключиться не
    /// вышло» — разные новости, и вторая опаснее. Трафик при этом продолжает
    /// идти в туннель, которым никто не управляет.
    case tunStuck = "tun_stuck"

    public var title: String {
        switch self {
        case .idle:       return "Отключено"
        case .connecting: return "Подключение…"
        case .connected:  return "Подключено"
        case .error:      return "Не подключилось"
        case .tunStuck:   return "Туннель не снят"
        }
    }

    /// Вид кольца кнопки питания.
    ///
    /// **Цветом состояния в чёрно-белой теме не различить**, поэтому кольцо
    /// меняет ещё и форму: подключено — толстое сплошное, ошибка — пунктир,
    /// простой — тонкое приглушённое. Убери форму, оставив яркость, и
    /// «подключено» с «ошибкой» станут неотличимы.
    public var ring: (color: String, width: Double, dashed: Bool) {
        switch self {
        case .idle:       return (Palette.muted, 3, false)
        case .connecting: return (Palette.text, 3, false)
        case .connected:  return (Palette.accent, 5, false)
        case .error:      return (Palette.text, 3, true)
        // Кольцо толстое, как у «подключено» (трафик и правда идёт через VPN),
        // но пунктиром — это не рабочее состояние, а то, что надо разбирать.
        case .tunStuck:   return (Palette.text, 5, true)
        }
    }
}

public let tunStuckText = """
    sing-box пережил остановку: TUN-адаптер поднят, весь трафик по-прежнему
    идёт через него, а туннель уже никем не обслуживается.

    Перезагрузка компьютера снимет адаптер наверняка.
    """

/// Результат замера пинга.
public enum PingResult: Equatable, Sendable {
    /// Ещё не мерили.
    case unknown
    /// Мерили, сервер не ответил.
    case noAnswer
    case ms(Int)
}

/// Подпись и цвет для значения пинга.
///
/// В чёрно-белой теме «хорошо/плохо» показывается яркостью: чем медленнее, тем
/// тусклее. **Отсутствие ответа подписано словами** — одной яркости для такого
/// важного случая мало.
public func pingLabel(_ ping: PingResult) -> (text: String, color: String) {
    switch ping {
    case .unknown:  return ("", Palette.dim)
    case .noAnswer: return ("нет ответа", Palette.muted)
    case .ms(let value):
        if value < 200 { return ("\(value) мс", Palette.text) }
        if value < 500 { return ("\(value) мс", Palette.dim) }
        return ("\(value) мс", Palette.muted)
    }
}

/// Режим подключения.
public enum VPNMode: String, Sendable {
    /// Системный прокси — уважают приложения с интерфейсом.
    case proxy
    /// Весь трафик через TUN. Нужен системный компонент.
    case tun
}

/// Длительность подключения в виде `1:02:03` или `02:03`.
public func formatUptime(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%02d:%02d", m, sec)
}
