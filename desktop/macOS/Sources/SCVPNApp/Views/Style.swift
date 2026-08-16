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

    // MARK: Разрядка
    //
    // Разрядка тем шире, чем мельче и «служебнее» надпись: у знака и у
    // заголовков разделов она растягивает строку в полоску, а у крупного
    // статуса, наоборот, стягивает — иначе 26 pt рассыпаются на буквы.

    /// Заголовки разделов и подписи вроде «СЕРВЕРЫ».
    static let sectionTracking: CGFloat = 2
    /// Надпись SCVPN в шапке.
    static let wordmarkTracking: CGFloat = 4
    /// Крупная надпись состояния.
    static let statusTracking: CGFloat = -0.4

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
///
/// **Шкала строится на одном крупном размере.** Раньше всё лежало в узкой
/// вилке 10–20 pt, и главная надпись окна — состояние подключения — весила
/// почти столько же, сколько имя сервера в списке: глазу было не за что
/// зацепиться. Теперь состояние забирает 26 pt, а всё служебное уходит вниз,
/// в 10–13 pt. Промежуточных размеров нет намеренно: каждый лишний шаг шкалы
/// снова размывает разницу.
///
/// **Цифры везде табличные.** Аптайм тикает раз в секунду, пинг меняется на
/// каждом замере, и пропорциональные цифры дёргали разметку на каждом
/// обновлении: строка «00:11:59 · весь трафик» шире, чем «00:12:00».
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
    ///
    /// Мельче прежнего: со своей разрядкой знак читается как метка окна, а не
    /// как заголовок, и перестаёт спорить со строкой состояния.
    static var wordmark: Font { .system(size: 12, weight: .bold) }

    /// Состояние подключения — единственная крупная надпись в окне.
    static var statusBig: Font { .system(size: 26, weight: .semibold) }

    /// Строка под состоянием: аптайм и режим, поэтому цифры табличные.
    static var substatus: Font { .system(size: 12).monospacedDigit() }

    static var section: Font { .system(size: 10, weight: .bold) }

    /// Имя сервера в списке. Полужирности хватает, чтобы имя отделилось от
    /// адреса под ним без увеличения размера.
    static var rowTitle: Font { .system(size: 13, weight: .medium) }

    /// Адрес под именем сервера.
    static var rowDetail: Font { .system(size: 11) }

    /// Значение пинга: те же 11 pt, но цифры табличные — колонка не пляшет
    /// при перезамере.
    static var rowPing: Font { .system(size: 11).monospacedDigit() }
}
