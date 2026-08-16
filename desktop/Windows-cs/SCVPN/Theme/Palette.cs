using System.Windows.Media;

namespace SCVPN.Theme;

/// <summary>
/// Палитра приложения. Тема одна: чёрно-белая. Цвета нет вообще, только
/// градации серого — поэтому состояния приходится различать не оттенком, а
/// формой: кольцо кнопки при ошибке рисуется пунктиром, при подключении —
/// толще, а «плохой» пинг вдобавок к приглушённому серому подписан словами.
/// Если бы состояния отличались только яркостью, «подключено» и «ошибка»
/// читались бы одинаково.
///
/// Те же значения продублированы в android/app/src/main/res/values/colors.xml
/// и в core-swift/Sources/SCVPNCore/Theme.swift. Расхождение сегодня никем не
/// замечается, кроме пользователя с двумя устройствами, поэтому его ловит
/// тест PaletteTests — он читает colors.xml прямо из дерева репозитория.
/// </summary>
public static class Palette
{
    public const string Bg = "#000000";
    public const string Surface = "#0D0D0D";
    public const string SurfaceHi = "#1C1C1C";
    public const string Stroke = "#333333";

    public const string Text = "#FFFFFF";
    public const string Dim = "#8C8C8C";
    public const string Muted = "#5A5A5A";

    /// <summary>Акцент — тоже белый: выделение показывается яркостью и рамкой, не цветом.</summary>
    public const string Accent = "#FFFFFF";

    /// <summary>Все цвета палитры — по ним проходит тест сверки с Android.</summary>
    public static readonly string[] All =
    {
        Bg, Surface, SurfaceHi, Stroke, Text, Dim, Muted, Accent,
    };

    /// <summary>Имена, под которыми те же цвета лежат в colors.xml Android-версии.</summary>
    public static readonly (string Name, string Value)[] Named =
    {
        ("bg", Bg),
        ("surface", Surface),
        ("surface_hi", SurfaceHi),
        ("stroke", Stroke),
        ("text", Text),
        ("text_dim", Dim),
        ("muted", Muted),
        ("accent", Accent),
    };

    public static Color Parse(string hex)
    {
        return (Color)ColorConverter.ConvertFromString(hex);
    }

    public static SolidColorBrush Brush(string hex)
    {
        var brush = new SolidColorBrush(Parse(hex));
        brush.Freeze();   // кисти общие на всё приложение, менять их никто не должен
        return brush;
    }

    public static readonly SolidColorBrush BgBrush = Brush(Bg);
    public static readonly SolidColorBrush SurfaceBrush = Brush(Surface);
    public static readonly SolidColorBrush SurfaceHiBrush = Brush(SurfaceHi);
    public static readonly SolidColorBrush StrokeBrush = Brush(Stroke);
    public static readonly SolidColorBrush TextBrush = Brush(Text);
    public static readonly SolidColorBrush DimBrush = Brush(Dim);
    public static readonly SolidColorBrush MutedBrush = Brush(Muted);
    public static readonly SolidColorBrush AccentBrush = Brush(Accent);
}
