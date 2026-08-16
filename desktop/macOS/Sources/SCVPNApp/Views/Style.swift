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
    //
    // Вертикаль шапки менять нельзя: `HeaderMetrics` задаёт её и ядру, и
    // AppKit — по тем же числам опускается светофор. Сдвинь высоту или
    // верхний отступ здесь, и кнопки окна разъедутся с надписью.

    /// Размер значка в кнопке шапки.
    static let headerIcon: CGFloat = 14
    /// Просвет между кнопками: ноль. Подложек у них больше нет, и только
    /// вплотную они читаются как одна группа, а не как четыре знака подряд.
    static let headerSpacing: CGFloat = 0
    /// Правый край группы кнопок. Совпадает с краем карточек списка — это и
    /// есть общая сетка окна.
    static let headerTrailing: CGFloat = 16
    static let headerBottom: CGFloat = 10

    /// Толщина разделительных линий.
    static let hairline: CGFloat = 1

    // MARK: Кнопка питания и статус

    /// Кнопка — единственный объёмный элемент окна, поэтому она крупная.
    static let powerSide: CGFloat = 156
    /// Секунд на оборот бегущей дуги.
    static let powerSpin: Double = 1.4
    /// Доля окружности, которую занимает дуга.
    static let powerArc: Double = 100.0 / 360.0
    /// Насколько притушено кольцо-подложка под бегущей дугой.
    static let powerTrackOpacity: Double = 0.22

    /// Внутренняя кромка шайбы: отступ от кольца состояния в долях стороны.
    static let powerEdgeInset: CGFloat = 0.11
    /// Секунд на полный вдох-выдох кольца в простое.
    static let powerBreath: Double = 3.6
    /// До какой яркости кольцо притухает на выдохе.
    static let powerBreathLow: Double = 0.5
    /// Частота перерисовки «дыхания». Двадцать четыре кадра хватает для
    /// медленного затухания, а окно висит открытым часами — гонять ради него
    /// полный refresh rate незачем.
    static let powerBreathFPS: Double = 24

    /// Переход между состояниями подключения.
    ///
    /// Четверть секунды — столько, чтобы глаз успел заметить смену и не
    /// начал ждать. Дольше означало бы, что после нажатия кнопка ещё
    /// раздумывает, хотя ядро уже стартовало.
    static let stateChange: Animation = .easeInOut(duration: 0.25)

    /// Пустоты вокруг блока ужаты: кнопка выросла до 156, и прежние отступы
    /// отдавали ей треть окна, оставляя списку четыре строки.
    static let powerBlockPadding: CGFloat = 14
    static let statusTop: CGFloat = 12
    static let substatusTop: CGFloat = 4
    static let substatusPadding: CGFloat = 20
    /// Между строкой подробностей и подписью режима.
    static let substatusLineGap: CGFloat = 4
    /// Высота фиксирована: подстатус меняется с одной строки на две, и без
    /// фиксации список серверов подпрыгивал бы при каждом переключении.
    static let substatusHeight: CGFloat = 34

    // MARK: Заголовок раздела

    /// Заголовок раздела встаёт ровно над именами серверов, а не над краем
    /// строки: колонка текста — самая заметная вертикаль в списке.
    static var sectionPadding: CGFloat { listPadding + rowMarker + rowTextLeading }
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

    /// Просвета между строками нет: их разделяет линия, а не пустота.
    static let listSpacing: CGFloat = 0
    /// Поле слева и справа от содержимого строки. Подсветка под курсором при
    /// этом идёт от края до края — нажимается вся полоса, а не карточка.
    static let listPadding: CGFloat = 16
    static let listBottom: CGFloat = 10

    /// Без карточки и её внутренних полей строка стала ниже на 6.
    static let rowHeight: CGFloat = 52
    /// Ширина маркера выбранной строки.
    static let rowMarker: CGFloat = 2
    /// Насколько маркер короче строки сверху и снизу.
    static let rowMarkerInset: CGFloat = 13
    /// От маркера до текста.
    static let rowTextLeading: CGFloat = 12
    /// Между именем сервера и строкой с адресом.
    static let rowTextSpacing: CGFloat = 3
    /// Между текстом и пингом.
    static let rowGap: CGFloat = 8

    static let stroke: CGFloat = 1

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
