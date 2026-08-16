using System.Globalization;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace SCVPN.Controls;

/// <summary>
/// Однострочная подпись, обрезанная С НАЧАЛА. Порт _HeadElidedLabel из
/// ui/widgets.py.
///
/// У сообщения ядра важен хвост: «[!] Не удалось…» с обрезанным концом не
/// говорит ничего, а начало строки — это метка уровня, которую видно и так.
/// Штатного средства для этого нет: TextTrimming умеет резать только хвост,
/// поэтому текст рисуется вручную.
/// </summary>
public class HeadElidedTextBlock : FrameworkElement
{
    private const string Ellipsis = "…";

    public static readonly DependencyProperty FullTextProperty = DependencyProperty.Register(
        nameof(FullText),
        typeof(string),
        typeof(HeadElidedTextBlock),
        new FrameworkPropertyMetadata(string.Empty, FrameworkPropertyMetadataOptions.AffectsRender));

    // Шрифт и цвет — те же свойства, что у остального текста в окне: взяты у
    // TextElement вместе с наследованием, чтобы подпись слушалась стиля окна и
    // Theme.xaml, а не заводила собственную шкалу.
    public static readonly DependencyProperty ForegroundProperty =
        TextElement.ForegroundProperty.AddOwner(
            typeof(HeadElidedTextBlock),
            new FrameworkPropertyMetadata(
                Theme.Palette.TextBrush,
                FrameworkPropertyMetadataOptions.Inherits | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FontSizeProperty =
        TextElement.FontSizeProperty.AddOwner(
            typeof(HeadElidedTextBlock),
            new FrameworkPropertyMetadata(
                Theme.Metrics.FsMono,
                FrameworkPropertyMetadataOptions.Inherits
                | FrameworkPropertyMetadataOptions.AffectsMeasure
                | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FontFamilyProperty =
        TextElement.FontFamilyProperty.AddOwner(
            typeof(HeadElidedTextBlock),
            new FrameworkPropertyMetadata(
                new FontFamily(Theme.Metrics.MonoFont),
                FrameworkPropertyMetadataOptions.Inherits
                | FrameworkPropertyMetadataOptions.AffectsMeasure
                | FrameworkPropertyMetadataOptions.AffectsRender));

    public HeadElidedTextBlock()
    {
        // Единственный случай, когда текст не влезает после подрезки, — полоса
        // уже́ самого многоточия. Тогда лишнее должно уйти под край, а не
        // нарисоваться поверх соседей.
        ClipToBounds = true;
    }

    public string FullText
    {
        get => (string)GetValue(FullTextProperty);
        set => SetValue(FullTextProperty, value);
    }

    public Brush Foreground
    {
        get => (Brush)GetValue(ForegroundProperty);
        set => SetValue(ForegroundProperty, value);
    }

    public double FontSize
    {
        get => (double)GetValue(FontSizeProperty);
        set => SetValue(FontSizeProperty, value);
    }

    public FontFamily FontFamily
    {
        get => (FontFamily)GetValue(FontFamilyProperty);
        set => SetValue(FontFamilyProperty, value);
    }

    /// <summary>Высота строки шрифта, а не нарисованного текста: полоса не
    /// должна прыгать оттого, что в сообщении не встретилось букв с хвостами.</summary>
    private double LineHeight => FontFamily.LineSpacing * FontSize;

    protected override Size MeasureOverride(Size availableSize)
    {
        // Ширину у раскладки не просим вовсе (в Qt это было QSizePolicy.Ignored):
        // длинная строка ядра требовала бы её целиком и растягивала окно. Ширину
        // полосе даёт раскладка, а текст подрезается под неё.
        return new Size(0, LineHeight);
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo info)
    {
        base.OnRenderSizeChanged(info);
        // Подрезка считается от ActualWidth, поэтому смена ширины — повод
        // перерисоваться (в Qt то же самое делал resizeEvent).
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        string full = FullText;
        double width = ActualWidth;
        if (string.IsNullOrEmpty(full) || width <= 0)
        {
            return;
        }

        FormattedText text = Build(full);
        if (text.Width > width)
        {
            text = Build(ElideHead(full, width));
        }

        dc.DrawText(text, new Point(0, (ActualHeight - text.Height) / 2));
    }

    private string ElideHead(string text, double width)
    {
        // Двоичный поиск по числу съеденных с головы знаков: строка ядра бывает
        // в тысячу символов, и посимвольное укорачивание строило бы тысячу
        // FormattedText на каждую перерисовку полосы.
        int lo = 1;
        int hi = text.Length;
        string best = Ellipsis;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2;
            string candidate = Ellipsis + text.Substring(mid);
            if (Build(candidate).Width <= width)
            {
                best = candidate;
                hi = mid - 1;
            }
            else
            {
                lo = mid + 1;
            }
        }

        return best;
    }

    private FormattedText Build(string text)
    {
        return new FormattedText(
            text,
            CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            // Начертание всегда обычное: подпись нужна ровно одна — строка лога.
            new Typeface(FontFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            FontSize,
            Foreground,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
    }
}
