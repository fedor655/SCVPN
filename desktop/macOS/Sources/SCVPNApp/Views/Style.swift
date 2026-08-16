import SCVPNCore
import SwiftUI

/// Метрики и шрифты окна macOS — одно место на весь главный экран.
///
/// Цвета сюда не переезжают: они живут строками в `SCVPNCore.Palette` и оттуда
/// же сверяются с `android/.../colors.xml`. Второй список цветов разошёлся бы с
/// Android молча. Здесь только размеры, радиусы, толщины и шрифты — то, чем
/// окно macOS отличается от телефона и что меняется при перекройке интерфейса.
///
/// Геометрия шапки, завязанная на светофор (`HeaderMetrics`), тоже остаётся в
/// ядре: её проверяет тест, а кнопки окна двигает AppKit, а не SwiftUI.
enum Style {

    // MARK: Шапка

    /// Размер значка в кнопке шапки.
    static let headerIcon: CGFloat = 15
    static let headerButtonCorner: CGFloat = 8
    /// Просвет между кнопками справа.
    static let headerSpacing: CGFloat = 2
    static let headerTrailing: CGFloat = 12
    static let headerBottom: CGFloat = 10

    // MARK: Кнопка питания и статус

    static let powerSide: CGFloat = 132
    /// Секунд на оборот бегущей дуги.
    static let powerSpin: Double = 1.4
    /// Доля окружности, которую занимает дуга.
    static let powerArc: Double = 100.0 / 360.0
    /// Насколько притушено кольцо-подложка под бегущей дугой.
    static let powerTrackOpacity: Double = 0.22

    static let powerBlockPadding: CGFloat = 24
    static let statusTop: CGFloat = 18
    static let substatusTop: CGFloat = 5
    static let substatusPadding: CGFloat = 20
    /// Высота фиксирована: подстатус меняется с одной строки на две, и без
    /// фиксации список серверов подпрыгивал бы при каждом переключении.
    static let substatusHeight: CGFloat = 32

    // MARK: Заголовок раздела

    static let sectionPadding: CGFloat = 22
    static let sectionBottom: CGFloat = 8
    /// Разрядка у заголовков разделов и подписей вроде «СЕРВЕРЫ».
    static let sectionTracking: CGFloat = 1.5
    /// Разрядка надписи SCVPN в шапке.
    static let wordmarkTracking: CGFloat = 3

    // MARK: Список серверов

    static let listSpacing: CGFloat = 4
    static let listPadding: CGFloat = 16
    static let listBottom: CGFloat = 10

    static let rowHeight: CGFloat = 58
    static let rowCorner: CGFloat = 10
    static let rowPaddingH: CGFloat = 14
    static let rowPaddingV: CGFloat = 10
    /// Между именем сервера и строкой с адресом.
    static let rowTextSpacing: CGFloat = 3
    /// Между текстом и пингом.
    static let rowGap: CGFloat = 8

    static let stroke: CGFloat = 1
    /// Обводка выбранной строки.
    static let strokeSelected: CGFloat = 1.5

    // MARK: Лог

    static let logHeight: CGFloat = 130
    static let logCorner: CGFloat = 8
    static let logPadding: CGFloat = 8
    static let logLineSpacing: CGFloat = 1
    static let logInsets = EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)
}

/// Шрифты окна macOS.
///
/// Знак и цвета живут в `SCVPNCore/UI/`: они одинаковы на macOS и iOS, а
/// размеры и Menlo — про десктопное окно.
extension Font {
    /// Системный шрифт интерфейса: на macOS это SF.
    static func scvpnUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Моноширинный для логов — Menlo, как в Python-версии.
    static func scvpnMono(_ size: CGFloat) -> Font {
        .custom("Menlo", size: size)
    }

    /// Надпись SCVPN в шапке: разрядка задаётся отдельно, через `.tracking`.
    static var wordmark: Font { .system(size: 14, weight: .bold) }
    static var statusBig: Font { .system(size: 20, weight: .bold) }
    static var substatus: Font { .system(size: 12) }
    static var section: Font { .system(size: 10, weight: .bold) }
    /// Имя сервера в списке.
    static var rowTitle: Font { .system(size: 13) }
    /// Адрес под именем и значение пинга.
    static var rowDetail: Font { .system(size: 11) }
}
