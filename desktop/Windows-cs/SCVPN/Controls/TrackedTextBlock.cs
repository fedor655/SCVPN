using System;
using System.Globalization;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace SCVPN.Controls;

/// <summary>
/// Текст с разрядкой — тем, чего в WPF нет вовсе.
///
/// Разрядка тем шире, чем мельче и служебнее надпись: у знака SCVPN и
/// заголовков разделов она растягивает строку в полоску, у крупного статуса —
/// наоборот стягивает, иначе 26 единиц рассыпаются на буквы. В Qt это жило в
/// QFont (таблица стилей `letter-spacing` не понимала и молча выбрасывала), а
/// здесь приходится рисовать по буквам: строка собирается из отдельных
/// FormattedText, каждая следующая сдвигается на Tracking.
///
/// Побочные следствия ручной раскладки: кернинг между соседними буквами
/// теряется, а суррогатные пары распались бы на два квадрата. Надписей с
/// разрядкой в окне ровно три — «SCVPN», состояние подключения и заголовки
/// разделов, — и ни в одной этого не видно.
/// </summary>
public class TrackedTextBlock : FrameworkElement
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text),
        typeof(string),
        typeof(TrackedTextBlock),
        new FrameworkPropertyMetadata(
            string.Empty,
            FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty TrackingProperty = DependencyProperty.Register(
        nameof(Tracking),
        typeof(double),
        typeof(TrackedTextBlock),
        new FrameworkPropertyMetadata(
            0.0,
            FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    // Цвет, размер и начертание берём у TextElement вместе с наследованием:
    // подпись должна слушаться стиля окна, а не заводить свою шкалу.
    public static readonly DependencyProperty ForegroundProperty =
        TextElement.ForegroundProperty.AddOwner(
            typeof(TrackedTextBlock),
            new FrameworkPropertyMetadata(
                Theme.Palette.TextBrush,
                FrameworkPropertyMetadataOptions.Inherits | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FontSizeProperty =
        TextElement.FontSizeProperty.AddOwner(
            typeof(TrackedTextBlock),
            new FrameworkPropertyMetadata(
                Theme.Metrics.FsRowTitle,
                FrameworkPropertyMetadataOptions.Inherits
                | FrameworkPropertyMetadataOptions.AffectsMeasure
                | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FontWeightProperty =
        TextElement.FontWeightProperty.AddOwner(
            typeof(TrackedTextBlock),
            new FrameworkPropertyMetadata(
                FontWeights.Normal,
                FrameworkPropertyMetadataOptions.Inherits
                | FrameworkPropertyMetadataOptions.AffectsMeasure
                | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FontFamilyProperty =
        TextElement.FontFamilyProperty.AddOwner(
            typeof(TrackedTextBlock),
            new FrameworkPropertyMetadata(
                new FontFamily(Theme.Metrics.UiFont),
                FrameworkPropertyMetadataOptions.Inherits
                | FrameworkPropertyMetadataOptions.AffectsMeasure
                | FrameworkPropertyMetadataOptions.AffectsRender));

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public double Tracking
    {
        get => (double)GetValue(TrackingProperty);
        set => SetValue(TrackingProperty, value);
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

    public FontWeight FontWeight
    {
        get => (FontWeight)GetValue(FontWeightProperty);
        set => SetValue(FontWeightProperty, value);
    }

    public FontFamily FontFamily
    {
        get => (FontFamily)GetValue(FontFamilyProperty);
        set => SetValue(FontFamilyProperty, value);
    }

    /// <summary>Высота строки шрифта, а не нарисованного текста: иначе надпись
    /// смещалась бы по вертикали в зависимости от того, какие буквы в неё попали.</summary>
    private double LineHeight => FontFamily.LineSpacing * FontSize;

    protected override Size MeasureOverride(Size availableSize)
    {
        return new Size(TextWidth(), LineHeight);
    }

    protected override void OnRender(DrawingContext dc)
    {
        string text = Text;
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        double y = (ActualHeight - LineHeight) / 2;
        double x = 0;
        foreach (char c in text)
        {
            FormattedText glyph = Build(c);
            dc.DrawText(glyph, new Point(x, y));
            x += glyph.WidthIncludingTrailingWhitespace + Tracking;
        }
    }

    private double TextWidth()
    {
        string text = Text;
        if (string.IsNullOrEmpty(text))
        {
            return 0;
        }

        // Разрядка добавляется и после последней буквы — так же, как её считал
        // Qt (QFont.AbsoluteSpacing). Разница видна только при центрировании
        // (надпись уходит влево на половину разрядки), зато знак и статус
        // встают там же, где стояли раньше.
        double width = 0;
        foreach (char c in text)
        {
            width += Build(c).WidthIncludingTrailingWhitespace + Tracking;
        }

        return Math.Max(0, width);
    }

    private FormattedText Build(char c)
    {
        return new FormattedText(
            c.ToString(),
            CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface(FontFamily, FontStyles.Normal, FontWeight, FontStretches.Normal),
            FontSize,
            Foreground,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
    }
}
