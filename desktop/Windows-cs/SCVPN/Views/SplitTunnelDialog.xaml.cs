using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SCVPN.Core;
using SCVPN.Native;
using SCVPN.Theme;

namespace SCVPN.Views;

/// <summary>
/// Раздельное туннелирование: что и как пускать через VPN. Порт
/// ui/split_dialog.py.
///
/// Три взаимоисключающих варианта:
///   * «Всё через VPN» — без исключений;
///   * два варианта по приложениям — их различает уже sing-box по
///     процессу-владельцу соединения, поэтому они работают только в
///     TUN-режиме: системный прокси — это настройка ОС, приложения ходят в
///     неё сами, и различить их там нечем.
///
/// В Qt-версии здесь был и четвёртый вариант — «Авто» (российские сайты
/// напрямую): там маршрутизация и выбор приложений были сведены в одно окно,
/// потому что это один и тот же вопрос «что идёт в туннель». Здесь режим
/// маршрутизации остался в меню главного окна, поэтому окно отвечает только за
/// split_mode — так задан его конструктор в контракте интерфейса.
///
/// Список приложений набираем из запущенных процессов — так не нужно ходить
/// по диску и гадать, как называется нужный файл.
/// </summary>
public partial class SplitTunnelDialog : Window
{
    // ------------------------------------------------------------------
    // Разметочные величины для XAML. Thickness и CornerRadius в разметке из
    // отдельных чисел не собираются, а вписывать числа руками нельзя — они
    // живут в Theme.Metrics. Поэтому статические поля, на них ссылается
    // {x:Static} в SplitTunnelDialog.xaml.

    /// <summary>
    /// FontFamily, а не строка из Metrics: значение markup-расширения
    /// {x:Static} присваивается свойству как есть, без преобразователя типов,
    /// поэтому строку в FontFamily тут никто не превратит.
    /// </summary>
    public static readonly FontFamily UiFont = new(Metrics.UiFont);

    /// <summary>Высота окна из ui/split_dialog.py. В Metrics её нет: ширина у
    /// окон поверх главного общая, а высота у каждого своя.</summary>
    public const double DialogHeight = 560;

    /// <summary>
    /// Ниже этого окно сжимать нечего: список приложений схлопнется в полосу.
    /// В Qt минимум считался по разметке сам, WPF так не умеет — приходится
    /// называть число.
    /// </summary>
    public const double DialogMinHeight = 420;

    /// <summary>Поля окна — общие для всех окон поверх главного.</summary>
    public static readonly Thickness SheetPadding =
        new(Metrics.SheetPadH, Metrics.SheetPadV, Metrics.SheetPadH, Metrics.SheetPadV);

    /// <summary>Просвет между блоками окна.</summary>
    public static readonly Thickness GapBelow = new(0, 0, 0, Metrics.SheetGap);

    // Собственные отступы переключателей, пояснения и строк списка — из
    // таблицы стилей прежней версии: `padding: 2px 0` у переключателей,
    // `4px 0 2px 0` у пояснения, `3px 0` у флажков, `padding: 6px` у панели
    // списка. В шкале Metrics их нет: это разметка одного окна.
    private const double RadioPad = 2;
    private const double NoteTopPad = 4;
    private const double NoteBottomPad = 2;
    private const double ItemPad = 3;
    private const double BoxPad = 6;

    public static readonly Thickness RadioMargin =
        new(0, RadioPad, 0, Metrics.SheetGap + RadioPad);
    public static readonly Thickness NoteMargin =
        new(0, NoteTopPad, 0, Metrics.SheetGap + NoteBottomPad);
    /// <summary>Просвет между кнопками в ряду — тот же, что между блоками окна.
    /// Qt-разметка брала его из стиля (6), но в C#-порте у соседних окон он уже
    /// равен SheetGap, и второй просвет между кнопками разошёлся бы с ними.</summary>
    public static readonly Thickness ButtonGap = new(0, 0, Metrics.SheetGap, 0);
    public static readonly Thickness BoxPadding = new(BoxPad);
    public static readonly Thickness BoxBorder = new(Metrics.StrokeWidth);
    public static readonly CornerRadius BoxCornerRadius = new(Metrics.BoxCorner);

    private static readonly Thickness ItemMargin = new(0, ItemPad, 0, ItemPad);

    // ------------------------------------------------------------------

    private List<string> _apps;

    public SplitTunnelDialog(string mode, IReadOnlyList<string> apps)
    {
        InitializeComponent();

        _apps = new List<string>(apps);
        Mode = string.IsNullOrEmpty(mode) ? SplitMode.Off : mode;
        // Отмена обязана вернуть то, с чем окно открыли, а не пустой список:
        // вызывающий читает Apps не глядя на DialogResult.
        Apps = new List<string>(_apps);

        if (Mode == SplitMode.Exclude)
        {
            RbExclude.IsChecked = true;
        }
        else if (Mode == SplitMode.Include)
        {
            RbInclude.IsChecked = true;
        }
        else
        {
            RbOff.IsChecked = true;
        }

        Fill();
    }

    /// <summary>SplitMode.Off | Exclude | Include.</summary>
    public string Mode { get; private set; }

    public List<string> Apps { get; private set; }

    /// <summary>
    /// Короткое описание выбора — для лога. Ветки про «авто» здесь нет: режим
    /// маршрутизации выбирается не в этом окне.
    /// </summary>
    public string Summary
    {
        get
        {
            if (Mode == SplitMode.Off || Apps.Count == 0)
            {
                return "всё через VPN";
            }

            string what = Mode == SplitMode.Exclude ? "кроме" : "только";
            return $"{what}: {string.Join(", ", Apps)}";
        }
    }

    // ------------------------------------------------------------------

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        // Подсказка встаёт ровно по левому краю текста поля. Числа берём у
        // самого поля, когда стиль темы уже применён: иначе отступ поля ввода
        // пришлось бы дублировать здесь и он молча разошёлся бы с темой.
        SearchHint.Margin = new Thickness(
            Search.Padding.Left + Search.BorderThickness.Left, 0,
            Search.Padding.Right + Search.BorderThickness.Right, 0);
    }

    /// <summary>Запущенные приложения плюс уже выбранные (даже если сейчас закрыты).</summary>
    /// <param name="chosen">
    /// Кого пометить галочками. null — взять текущие отметки списка, а если
    /// отмечено ничего (в том числе при первом заполнении) — то, что пришло из
    /// настроек. Второе поведение унаследовано от Python дословно: снять все
    /// галочки и нажать «Обновить список» возвращает исходный выбор.
    /// Явный параметр нужен ручному добавлению: Python-версия и там читала
    /// отметки со старого списка, и добавленное вручную имя незапущенного
    /// приложения молча терялось, стоило хоть одну галочку уже поставить.
    /// </param>
    private void Fill(IReadOnlyList<string>? chosen = null)
    {
        IReadOnlyList<string> picked = chosen ?? Collect();
        if (picked.Count == 0)
        {
            picked = _apps;
        }

        var checkedSet = new HashSet<string>(picked, StringComparer.OrdinalIgnoreCase);
        // Регистр имени процесса система не обещает, а правило sing-box
        // сравнивает имена без учёта регистра — иначе один и тот же Telegram.exe
        // попадал бы в список дважды.
        var names = new HashSet<string>(RunningApps.List(), StringComparer.OrdinalIgnoreCase);
        names.UnionWith(picked);

        AppsPanel.Children.Clear();
        foreach (string name in names.OrderBy(n => n, StringComparer.OrdinalIgnoreCase))
        {
            AppsPanel.Children.Add(new CheckBox
            {
                Content = name,
                IsChecked = checkedSet.Contains(name),
                Margin = ItemMargin,
            });
        }

        Filter(Search.Text);
        ApplyEnabled();
    }

    private void Filter(string text)
    {
        string needle = text.Trim();
        foreach (CheckBox item in Items())
        {
            string name = (string)item.Content;
            bool hidden = needle.Length > 0
                && name.IndexOf(needle, StringComparison.OrdinalIgnoreCase) < 0;
            // Строка прячется, а не удаляется: галочка на ней сохраняется —
            // поиск не должен молча снимать выбор с того, что не подошло.
            item.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    private IEnumerable<CheckBox> Items()
    {
        return AppsPanel.Children.OfType<CheckBox>();
    }

    private List<string> Collect()
    {
        return Items().Where(i => i.IsChecked == true).Select(i => (string)i.Content).ToList();
    }

    /// <summary>
    /// Список приложений нужен только двум вариантам из трёх.
    ///
    /// Выключенный список гасится палитрой (<see cref="Palette.Muted"/>), а не
    /// отдельным серым: второй список цветов в приложении разошёлся бы с
    /// остальными молча — в Qt-версии такой и лежал, зашитым мимо палитры.
    /// </summary>
    private void ApplyEnabled()
    {
        bool enabled = RbExclude.IsChecked == true || RbInclude.IsChecked == true;
        AppsBox.IsEnabled = enabled;
        Search.IsEnabled = enabled;

        SolidColorBrush brush = enabled ? Palette.TextBrush : Palette.MutedBrush;
        foreach (CheckBox item in Items())
        {
            item.Foreground = brush;
        }
    }

    // ------------------------------------------------------------------

    private void OnModeChanged(object sender, RoutedEventArgs e)
    {
        // Событие Checked приходит и во время конструктора, когда список ещё
        // не заполнен: ApplyEnabled на пустом списке просто ничего не красит.
        ApplyEnabled();
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        Filter(Search.Text);
    }

    private void OnReload(object sender, RoutedEventArgs e)
    {
        Fill();
    }

    private void OnAddManual(object sender, RoutedEventArgs e)
    {
        string? name = MessageDialog.Prompt(this, "Добавить приложение", RunningApps.ManualHint);
        if (name == null)
        {
            return;
        }

        name = name.Trim();
        if (name.Length == 0)
        {
            return;
        }

        // Приводим к виду, который поймёт правило sing-box: «Telegram» без
        // расширения не совпадёт ни с одним процессом.
        name = RunningApps.Normalize(name);
        var chosen = new HashSet<string>(Collect(), StringComparer.OrdinalIgnoreCase) { name };
        _apps = chosen.OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();
        Fill(_apps);
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (RbExclude.IsChecked == true)
        {
            Mode = SplitMode.Exclude;
        }
        else if (RbInclude.IsChecked == true)
        {
            Mode = SplitMode.Include;
        }
        else
        {
            Mode = SplitMode.Off;
        }

        // Отметки читаются со всего списка, включая скрытые фильтром строки.
        Apps = Collect();
        _apps = Apps;
        DialogResult = true;
    }
}
