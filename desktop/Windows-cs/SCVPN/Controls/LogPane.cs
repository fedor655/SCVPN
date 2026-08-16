using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using SCVPN.Theme;

namespace SCVPN.Controls;

/// <summary>
/// Лог ядра: полоса с последней строкой, по щелчку — разворот. Порт LogPane из
/// ui/widgets.py.
///
/// Раньше это была коробка в 130 единиц, занимавшая низ окна всегда — в том
/// числе пустая, пока ядро не запущено. Читают лог ради последней строки,
/// поэтому по умолчанию видна ровно она.
///
/// Развёрнутость нигде не сохраняется: это состояние взгляда, а не приложения —
/// лог разворачивают, чтобы посмотреть здесь и сейчас.
/// </summary>
public class LogPane : Control
{
    /// <summary>
    /// Потолок строк. В Qt это был QPlainTextEdit.setMaximumBlockCount(2000):
    /// ядро при переборе отпечатков сыплет сотнями строк в минуту, и без
    /// потолка окно съедало бы память ровно столько, сколько работает.
    /// </summary>
    private const int MaxLines = 2000;

    private const string EmptyText = "Лог ядра пуст";
    private const string ChevronCollapsed = "▸";
    private const string ChevronExpanded = "▾";

    private readonly Grid _root;
    private readonly Border _strip;
    private readonly TextBlock _chevron;
    private readonly HeadElidedTextBlock _last;
    private readonly TextBox _body;

    private readonly Queue<string> _lines = new();
    /// <summary>Очередь ушла вперёд текстового поля и его надо собрать заново.</summary>
    private bool _bodyStale;
    private bool _expanded;

    public LogPane()
    {
        // Control в WPF по умолчанию Focusable и стоит в обходе по Tab, а в Qt
        // это был обычный QWidget с Qt.NoFocus. Без этой строки Tab останавливался
        // бы на полосе лога, и остановка была бы не видна: рамку фокуса на ней
        // никто не рисует.
        Focusable = false;
        IsTabStop = false;

        _root = new Grid();
        // Фон задаётся здесь, а не через Background: Control без шаблона свой
        // Background не рисует, а полоса лога обязана быть темнее окна.
        _root.Background = Palette.SurfaceBrush;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Волосяная линия сверху: полосы заголовка у окна нет, и без линии лог
        // сливается со списком серверов.
        var line = new Border
        {
            Height = Metrics.Hairline,
            Background = Palette.StrokeBrush,
        };
        Grid.SetRow(line, 0);
        _root.Children.Add(line);

        _chevron = new TextBlock
        {
            Text = ChevronCollapsed,
            FontFamily = new FontFamily(Metrics.UiFont),
            FontSize = Metrics.FsSection,
            FontWeight = FontWeights.Bold,
            Foreground = Palette.MutedBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };

        _last = new HeadElidedTextBlock
        {
            FontFamily = new FontFamily(Metrics.MonoFont),
            FontSize = Metrics.FsMono,
            Foreground = Palette.DimBrush,
            FullText = EmptyText,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(Metrics.RowGap, 0, 0, 0),
        };

        var stripContent = new Grid();
        stripContent.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        stripContent.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(_chevron, 0);
        Grid.SetColumn(_last, 1);
        stripContent.Children.Add(_chevron);
        stripContent.Children.Add(_last);

        _strip = new Border
        {
            Height = Metrics.LogStripHeight,
            Background = Palette.SurfaceBrush,
            Padding = new Thickness(Metrics.ListPadding, 0, Metrics.ListPadding, 0),
            Cursor = Cursors.Hand,
            ToolTip = "Развернуть лог",
            Child = stripContent,
        };
        // Щелчок по всей полосе, а не по шеврону: попадать мышью в знак в
        // девять единиц — работа, которой пользователь не просил.
        _strip.MouseLeftButtonDown += OnStripClicked;
        Grid.SetRow(_strip, 1);
        _root.Children.Add(_strip);

        _body = new TextBox
        {
            IsReadOnly = true,
            IsTabStop = false,
            // Развёрнутый лог — не коробка, а нижняя часть полосы: рамка и
            // скругление отрезали бы его от строки с последним сообщением, а
            // это одно и то же.
            BorderThickness = new Thickness(0),
            Background = Palette.SurfaceBrush,
            Foreground = Palette.DimBrush,
            FontFamily = new FontFamily(Metrics.MonoFont),
            FontSize = Metrics.FsMono,
            Padding = new Thickness(Metrics.LogPadding),
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            // Свёрнутый лог занимает ноль по высоте, а не прячется: так его
            // можно разворачивать той же плавной сменой, что и состояние кнопки.
            Height = 0,
            MinHeight = 0,
        };
        Grid.SetRow(_body, 2);
        _root.Children.Add(_body);

        AddVisualChild(_root);
        AddLogicalChild(_root);
    }

    /// <summary>
    /// Дописать строку. Вызывать только из потока интерфейса: события ядра
    /// приходят из фоновых, и тот, кто на них подписан, обязан пройти через
    /// Dispatcher.
    /// </summary>
    public void Append(string text)
    {
        _lines.Enqueue(text);
        if (_lines.Count > MaxLines)
        {
            _lines.Dequeue();
            _bodyStale = true;
        }

        // В свёрнутом виде видна ровно последняя строка — она и есть весь лог
        // для того, кто на него смотрит.
        _last.FullText = text;

        if (!_expanded)
        {
            // Свёрнутый лог никто не читает, и складывать строки в поле ввода
            // незачем: соберём его целиком, когда лог откроют.
            _bodyStale = true;
            return;
        }

        if (_bodyStale)
        {
            FillBody();
        }
        else
        {
            _body.AppendText(_body.Text.Length == 0 ? text : "\n" + text);
            _body.ScrollToEnd();
        }
    }

    public bool IsExpanded
    {
        get => _expanded;
        set
        {
            if (value == _expanded)
            {
                return;
            }

            _expanded = value;
            _chevron.Text = value ? ChevronExpanded : ChevronCollapsed;
            _strip.ToolTip = value ? "Свернуть лог" : "Развернуть лог";

            if (value && _bodyStale)
            {
                // Наполняем до анимации, иначе лог раскрывается пустым и текст
                // появляется рывком в конце.
                FillBody();
            }

            var grow = new DoubleAnimation
            {
                // Начальное значение не задаём: анимация продолжится с той
                // высоты, на которой её застали, — щелчки подряд не дёргают.
                To = value ? Metrics.LogHeight : 0,
                Duration = new Duration(TimeSpan.FromMilliseconds(Metrics.StateChangeMs)),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut },
            };
            _body.BeginAnimation(HeightProperty, grow);
        }
    }

    public void Clear()
    {
        _lines.Clear();
        _body.Clear();
        _bodyStale = false;
        _last.FullText = EmptyText;
    }

    private void OnStripClicked(object sender, MouseButtonEventArgs e)
    {
        IsExpanded = !IsExpanded;
        e.Handled = true;
    }

    private void FillBody()
    {
        // Перестраиваем целиком: строки уже выпали из начала очереди, и
        // дописать поле с конца нельзя. Случается это, только когда лог открыт
        // и уже упёрся в потолок в две тысячи строк.
        _body.Text = string.Join("\n", _lines);
        _bodyStale = false;
        _body.ScrollToEnd();
    }

    // Control без шаблона собственного содержимого не имеет, поэтому дерево
    // собрано в конструкторе и подвешено вручную. Шаблон здесь был бы лишним:
    // ни одного места, где полосу лога надо перерисовать иначе, в приложении нет.
    protected override int VisualChildrenCount => 1;

    protected override Visual GetVisualChild(int index) => _root;

    protected override Size MeasureOverride(Size constraint)
    {
        _root.Measure(constraint);
        return _root.DesiredSize;
    }

    protected override Size ArrangeOverride(Size arrangeBounds)
    {
        _root.Arrange(new Rect(arrangeBounds));
        return arrangeBounds;
    }
}
