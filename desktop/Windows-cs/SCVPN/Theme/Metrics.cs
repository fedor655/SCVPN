using System.Windows.Media;

namespace SCVPN.Theme;

/// <summary>
/// Метрики окна. Те же числа, что в desktop/macOS/.../Views/Style.swift и в
/// прежнем ui/theme.py: окно обязано узнаваться на всех платформах, а
/// разъезжаются размеры молча — их никто не сверяет тестом, в отличие от
/// цветов. Поэтому один список на весь клиент, и правится он вместе со
/// Style.swift.
///
/// Единицы: в Qt это были пиксели при 96 DPI, в WPF — независимые от
/// устройства единицы того же размера. При масштабе 100% числа совпадают,
/// на 150% WPF масштабирует их сам — чего Qt-версия не делала.
/// </summary>
public static class Metrics
{
    // Системный шрифт интерфейса.
    public const string UiFont = "Segoe UI";
    public const string MonoFont = "Consolas";

    // Те же шрифты готовыми объектами. Нужны для разметки: {x:Static} отдаёт
    // значение как есть, преобразователь типов к нему не применяется, и строка
    // в свойстве FontFamily упала бы при разборе XAML.
    public static readonly FontFamily UiFontFamily = new FontFamily(UiFont);
    public static readonly FontFamily MonoFontFamily = new FontFamily(MonoFont);

    // --- Окно ---
    public const double WindowWidth = 420;
    public const double WindowHeight = 700;
    public const double WindowMinWidth = 360;
    public const double WindowMinHeight = 540;

    // --- Шапка ---
    public const double HeaderTop = 12;
    public const double HeaderBottom = 10;
    public const double HeaderButton = 28;
    /// <summary>Размер самого знака в кнопке шапки.</summary>
    public const double HeaderIcon = 14;
    /// <summary>
    /// Просвет между кнопками: ноль. Подложек у них больше нет, и только
    /// вплотную они читаются как одна группа, а не как четыре знака подряд.
    /// </summary>
    public const double HeaderSpacing = 0;
    public const double HeaderTrailing = 16;
    /// <summary>От знака «S» до слова SCVPN.</summary>
    public const double HeaderBadgeGap = 10;

    // Толщина разделительных линий.
    public const double Hairline = 1;
    public const double StrokeWidth = 1;

    // --- Кнопка питания ---
    /// <summary>Кнопка — единственный объёмный элемент окна, поэтому она крупная.</summary>
    public const double PowerSide = 156;
    /// <summary>Центр радиальной заливки: свет падает сверху, к краям шайба уходит в фон.</summary>
    public const double PowerLightX = 0.5;
    public const double PowerLightY = 0.34;
    public const double PowerLightRadius = 0.62;
    /// <summary>Внутренняя кромка шайбы: отступ от кольца состояния в долях стороны.</summary>
    public const double PowerEdgeInset = 0.11;
    /// <summary>Секунд на оборот бегущей дуги и её раскрытие в градусах.</summary>
    public const double PowerSpinSeconds = 1.4;
    public const double PowerArcDegrees = 100;
    /// <summary>Насколько притушено кольцо-подложка под бегущей дугой.</summary>
    public const double PowerTrackOpacity = 0.22;
    /// <summary>Секунд на полный вдох-выдох кольца в простое и до какой яркости оно притухает.</summary>
    public const double PowerBreathSeconds = 3.6;
    public const double PowerBreathLow = 0.5;
    // Частоты кадров из Qt-версии (24 и 60) сюда не переехали намеренно:
    // в WPF анимации ведёт композитор, он сам выбирает частоту и
    // останавливает анимацию в свёрнутом окне.

    /// <summary>
    /// Переход между состояниями, мс. Четверть секунды — столько, чтобы глаз
    /// успел заметить смену и не начал ждать.
    /// </summary>
    public const int StateChangeMs = 250;

    // --- Блок статуса ---
    public const double PowerBlockPadding = 14;
    public const double StatusTop = 12;
    public const double SubstatusTop = 4;
    public const double SubstatusPadding = 20;
    /// <summary>Между строкой подробностей и подписью режима.</summary>
    public const double SubstatusLineGap = 4;
    /// <summary>
    /// Высота блока подробностей. Он переключается с одной строки на две, и без
    /// запаса список серверов подпрыгивал бы при каждой смене состояния.
    /// </summary>
    public const double SubstatusHeight = 34;

    // --- Список серверов ---
    /// <summary>Просвета между строками нет: их разделяет линия, а не пустота.</summary>
    public const double ListSpacing = 0;
    /// <summary>
    /// Поле слева и справа от содержимого строки. Подсветка под курсором при
    /// этом идёт от края до края — нажимается вся полоса, а не карточка.
    /// </summary>
    public const double ListPadding = 16;
    public const double ListBottom = 10;
    public const double RowHeight = 52;
    /// <summary>Ширина маркера выбранной строки и насколько он короче строки сверху и снизу.</summary>
    public const double RowMarker = 2;
    public const double RowMarkerInset = 13;
    /// <summary>От маркера до текста.</summary>
    public const double RowTextLeading = 12;
    /// <summary>Между именем сервера и строкой с адресом.</summary>
    public const double RowTextSpacing = 3;
    /// <summary>Между текстом и пингом.</summary>
    public const double RowGap = 8;
    /// <summary>
    /// Ширина колонки пинга. Постоянная: иначе правый край значений гуляет от
    /// строки к строке и колонки не получается вовсе. Считана по самой длинной
    /// подписи — «нет ответа».
    /// </summary>
    public const double PingColumn = 72;

    /// <summary>
    /// Заголовок раздела встаёт ровно над именами серверов, а не над краем
    /// строки: колонка текста — самая заметная вертикаль в списке.
    /// </summary>
    public const double SectionPadding = ListPadding + RowMarker + RowTextLeading;
    public const double SectionBottom = 8;

    // --- Пустой список ---
    /// <summary>Между «что случилось» и «что делать».</summary>
    public const double EmptyGap = 8;
    public const double EmptyPadding = 24;

    // --- Лог ---
    /// <summary>Свёрнутая полоса с последней строкой и развёрнутый лог.</summary>
    public const double LogStripHeight = 26;
    public const double LogHeight = 130;
    public const double LogPadding = 8;

    // --- Окна поверх главного ---
    /// <summary>
    /// Ширина у всех одна. Раньше их было четыре — 420, 430, 440 и 520, — и
    /// окна прыгали по ширине, стоило открыть два подряд.
    /// </summary>
    public const double SheetWidth = 440;
    public const double SheetPadH = 18;
    public const double SheetPadV = 16;
    /// <summary>Между блоками внутри окна.</summary>
    public const double SheetGap = 10;
    /// <summary>
    /// Скругление вложенных панелей: поля ввода, списки, карточки подписок.
    /// Одно на всё — прежде соседние панели скруглялись на 8 и на 10.
    /// </summary>
    public const double BoxCorner = 8;

    // --- Шкала шрифтов ---
    // Шкала намеренно разорвана: 26 на состояние подключения и 10–13 на всё
    // остальное. Промежуточных размеров нет — каждый лишний шаг снова
    // размывает разницу между главной надписью окна и служебными.
    public const double FsStatus = 26;      // состояние подключения
    public const double FsRowTitle = 13;    // имя сервера, оно же базовый размер интерфейса
    public const double FsBody = 12;        // подстатус, тексты в окнах
    public const double FsDetail = 11;      // адрес, пинг, пояснения
    public const double FsSection = 10;     // подписи разделов
    public const double FsWordmark = 12;    // знак SCVPN
    public const double FsMono = 10;        // лог

    // Разрядка тем шире, чем мельче и служебнее надпись: у знака и заголовков
    // разделов она растягивает строку в полоску, у крупного статуса — наоборот
    // стягивает, иначе 26 пунктов рассыпаются на буквы.
    //
    // В WPF это TextBlock.SetValue(TextOptions...)? Нет: разрядки в WPF нет
    // вовсе, её приходится изображать вручную — см. Controls/TrackedText.cs.
    public const double SectionTracking = 2.0;
    public const double WordmarkTracking = 4.0;
    public const double StatusTracking = -0.4;
}
