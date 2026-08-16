using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

using SCVPN.Theme;

namespace SCVPN.Controls;

/// <summary>
/// Фирменный знак «S», нарисованный средствами WPF. Порт ui/brandmark.py.
///
/// Геометрия та же, что у готовых иконок и у macOS/Android-версий: две
/// касающиеся окружности, осевая обводится штрихом с круглыми концами, каждая
/// чаша раскрыта на 255°. Рисуем векторно, чтобы знак был чётким на любом
/// масштабе и его можно было перекрашивать под состояние.
///
/// Про углы. У PIL точка дуги — center + r·(cos a, sin a) при оси Y вниз, а Qt
/// считает углы против часовой (center + r·(cos θ, −sin θ)); в brandmark.py
/// дуги записаны уже в системе Qt. У WPF ось Y тоже вниз, но дуга задаётся не
/// углами, а конечной точкой и направлением обхода. Поэтому здесь оставлены
/// исходные углы Qt, а <see cref="OnCircle"/> переводит их в точки по формуле
/// самого Qt — так строчки ниже сверяются с Python буква в букву. Знак
/// направления при этом сохраняется: рост θ у Qt виден как обход против
/// часовой стрелки, что и есть SweepDirection.Counterclockwise.
/// </summary>
public static class Brandmark
{
    // Палитра — общая с иконкой и с Android. Знак белый; лёгкий переход к
    // светло-серому нужен только чтобы крупная фигура не выглядела плоской
    // заливкой.
    public const string MarkTop = "#FFFFFF";
    public const string MarkBottom = "#C4C4C4";

    private const double R = 0.155;      // радиус осевой в долях канвы
    private const double W = 0.090;      // толщина штриха в долях канвы
    private const double Sweep = 255;    // раскрытие каждой чаши, градусов

    // Границы фирменного градиента по вертикали, в долях канвы. Переход идёт
    // не от края до края: у самых концов штриха он был бы не виден.
    private const double GradientTop = 0.2;
    private const double GradientBottom = 0.8;

    /// <summary>Нарисовать знак внутри rect. brush = null — фирменный градиент.</summary>
    public static void Paint(DrawingContext dc, Rect rect, Brush? brush, double widthScale = 1.0)
    {
        double side = Math.Min(rect.Width, rect.Height);
        if (side <= 0)
        {
            return;
        }

        Brush paint;
        if (brush == null)
        {
            var grad = new LinearGradientBrush(
                Palette.Parse(MarkTop),
                Palette.Parse(MarkBottom),
                new Point(0, side * GradientTop),
                new Point(0, side * GradientBottom));
            // Absolute: градиент привязан к квадрату знака, а не к рамке
            // обводки — иначе переход поехал бы вместе с толщиной штриха.
            grad.MappingMode = BrushMappingMode.Absolute;
            grad.Freeze();
            paint = grad;
        }
        else
        {
            paint = brush;
        }

        var pen = new Pen(paint, side * W * widthScale);
        pen.StartLineCap = PenLineCap.Round;
        pen.EndLineCap = PenLineCap.Round;
        pen.LineJoin = PenLineJoin.Round;
        if (pen.CanFreeze)
        {
            pen.Freeze();
        }

        // Знак вписывается в квадрат по меньшей стороне и центрируется в rect.
        var offset = new TranslateTransform(
            rect.Left + (rect.Width - side) / 2,
            rect.Top + (rect.Height - side) / 2);
        offset.Freeze();

        dc.PushTransform(offset);
        dc.DrawGeometry(null, pen, MarkPath(side));
        dc.Pop();
    }

    /// <summary>Знак как картинка (для кнопок шапки и значка окна).</summary>
    public static ImageSource Image(double size, Brush? brush)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            Paint(dc, new Rect(0, 0, size, size), brush);
        }

        // Растр нужен там, где ImageSource обязан быть растром (значок окна и
        // панели задач). Рисуем вдвое плотнее и помечаем удвоенным dpi:
        // картинка остаётся размером size в единицах WPF, но на экране со
        // 150–200 % не мылится.
        const double density = 2.0;
        var bmp = new RenderTargetBitmap(
            (int)Math.Ceiling(size * density),
            (int)Math.Ceiling(size * density),
            96 * density,
            96 * density,
            PixelFormats.Pbgra32);
        bmp.Render(visual);
        bmp.Freeze();
        return bmp;
    }

    /// <summary>Путь знака, вписанный в квадрат size×size.</summary>
    private static Geometry MarkPath(double size)
    {
        double r = size * R;
        double cx = size / 2.0;
        double cy = size / 2.0;

        // Окружности касаются в самом центре канвы: нижняя точка верхней и
        // верхняя точка нижней — это одна и та же точка (cx, cy).
        var top = new Point(cx, cy - r);
        var bottom = new Point(cx, cy + r);

        var geo = new StreamGeometry();
        using (var ctx = geo.Open())
        {
            // Верхняя чаша: от свободного конца (θ=15°) по дуге до точки
            // касания (θ=270°). Рост θ — обход против часовой стрелки.
            ctx.BeginFigure(OnCircle(top, r, 15), false, false);
            ctx.ArcTo(OnCircle(top, r, 15 + Sweep), new Size(r, r), 0,
                Sweep > 180, SweepDirection.Counterclockwise, true, false);
            // Нижняя — от той же точки касания (θ=90° своей окружности) в
            // обратную сторону, оттого и Clockwise.
            ctx.ArcTo(OnCircle(bottom, r, 90 - Sweep), new Size(r, r), 0,
                Sweep > 180, SweepDirection.Clockwise, true, false);
        }

        geo.Freeze();
        return geo;
    }

    /// <summary>Точка на окружности по углу в системе Qt: против часовой, Y вниз.</summary>
    private static Point OnCircle(Point centre, double r, double angleDeg)
    {
        double a = angleDeg * Math.PI / 180.0;
        return new Point(centre.X + r * Math.Cos(a), centre.Y - r * Math.Sin(a));
    }
}
