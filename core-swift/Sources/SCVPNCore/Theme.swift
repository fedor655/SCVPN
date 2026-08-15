import Foundation

/// Палитра SCVPN — одно место на всё приложение.
///
/// Тема одна: чёрно-белая. Цвета нет вообще, только градации серого — поэтому
/// **состояния приходится различать не оттенком, а формой**: кольцо кнопки при
/// ошибке рисуется пунктиром, при подключении — толще, а «плохой» пинг вдобавок
/// к приглушённому серому подписан словами. Отличайся состояния только
/// яркостью, «подключено» и «ошибка» читались бы одинаково. Это осознанное
/// решение доступности, а не нехватка времени на палитру.
///
/// Те же значения продублированы в `android/app/src/main/res/values/colors.xml`
/// и сверяются проверкой — сегодня расхождение никем не ловится.
public enum Palette {
    public static let bg = "#000000"
    public static let surface = "#0D0D0D"
    public static let surfaceHi = "#1C1C1C"
    public static let stroke = "#333333"

    public static let text = "#FFFFFF"
    public static let dim = "#8C8C8C"
    public static let muted = "#5A5A5A"

    /// Акцент — тоже белый: выделение показывается яркостью и рамкой, не цветом.
    public static let accent = "#FFFFFF"

    /// Все цвета разом — для сверки с Android.
    public static let all = [bg, surface, surfaceHi, stroke, text, dim, muted, accent]
}

/// Геометрия шапки macOS.
///
/// Системной полосы заголовка у окна нет: содержимое заведено под неё, а
/// светофор опущен в центр этого ряда и отодвинут от края. Значения — те же,
/// что в Python-версии, иначе кнопки окна разъедутся с надписью.
public enum HeaderMetrics {
    public static let top: CGFloat = 12
    /// Слева оставлено место кнопкам окна.
    public static let left: CGFloat = 88
    public static let buttonSide: CGFloat = 28
    public static var height: CGFloat { top + buttonSide + 10 }
    /// Отступ первой кнопки светофора от края окна.
    public static let lightsLeft: CGFloat = 18
}

/// Фирменный знак «S».
///
/// Геометрия один в один как в `setup/brand.py` и `shared/ui/brandmark.py`: две
/// касающиеся окружности, осевая обводится штрихом с круглыми концами, каждая
/// чаша раскрыта на 255°.
public enum Brandmark {
    /// Радиус осевой в долях канвы.
    public static let radius: CGFloat = 0.155
    /// Толщина штриха в долях канвы.
    public static let strokeWidth: CGFloat = 0.090
    /// Раскрытие каждой чаши, градусов.
    public static let sweep: CGFloat = 255

    /// Лёгкий переход к светло-серому нужен только чтобы крупная фигура не
    /// выглядела плоской заливкой.
    public static let gradientTop = "#FFFFFF"
    public static let gradientBottom = "#C4C4C4"
}

/// Цвет из строки `#RRGGBB`.
///
/// Палитра хранится строками, а не готовыми цветами, ровно затем, чтобы её
/// можно было сверить с `colors.xml` посимвольно.
public func rgbComponents(_ hex: String) -> (r: Double, g: Double, b: Double)? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    return (Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255)
}
