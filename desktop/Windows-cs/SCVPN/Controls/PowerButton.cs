using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

using SCVPN.Theme;

namespace SCVPN.Controls;

/// <summary>
/// Круглая кнопка подключения. Порт PowerButton из ui/widgets.py.
/// <see cref="State"/>: idle | connecting | connected | error | tun_stuck.
///
/// Единственная вещь в окне, у которой есть объём: заливка идёт радиальным
/// переходом, будто свет падает сверху, а внутри кольца проходит кромка шайбы.
/// Всё остальное на экране плоское, поэтому взгляд идёт сюда первым.
///
/// Состояние показывается формой кольца, а не цветом: подключено — толстое
/// сплошное, ошибка — пунктир, простой — тонкое приглушённое. В чёрно-белой
/// теме иначе никак, и это осознанное решение доступности.
/// </summary>
public class PowerButton : ButtonBase
{
    private const string Idle = "idle";
    private const string Connecting = "connecting";
    private const string Connected = "connected";

    /// <summary>Доля стороны, которую занимает знак внутри шайбы (из ui/widgets.py).</summary>
    private const double MarkFraction = 0.48;

    /// <summary>Пунктир в долях толщины линии — как задавал его setDashPattern в Qt.</summary>
    private static readonly DoubleCollection DashPattern = MakeDashPattern();

    /// <summary>
    /// Формы колец приходят из ядра (SCVPNCore.ConnectionState.ring) и
    /// одинаковы на всех платформах — здесь их копия для WPF. Менять только
    /// вместе с ядром.
    /// </summary>
    private static readonly Dictionary<string, Ring> Rings = new Dictionary<string, Ring>
    {
        [Idle] = new Ring(Palette.MutedBrush, 3.0, false),
        [Connecting] = new Ring(Palette.TextBrush, 3.0, false),
        [Connected] = new Ring(Palette.AccentBrush, 5.0, false),
        ["error"] = new Ring(Palette.TextBrush, 3.0, true),
        // Просили отключиться, а туннель остался поднятым: кольцо толстое, как
        // у «подключено» (трафик и правда идёт через VPN), но пунктиром — это
        // не рабочее состояние, а то, что надо разбирать.
        ["tun_stuck"] = new Ring(Palette.TextBrush, 5.0, true),
    };

    /// <summary>Состояние, из которого сейчас растворяемся.</summary>
    private string _prevState = Idle;

    /// <summary>Анимация перехода, чтобы отличить свой Completed от чужого.</summary>
    private DoubleAnimation? _fadeAnim;

    // Бесконечные анимации держим включёнными только пока их состояние на
    // экране: иначе композитор гоняет кадры вхолостую и не даёт окну заснуть.
    private bool _spinning;
    private bool _breathing;

    public PowerButton()
    {
        // setFixedSize из Qt-версии: размер кнопки не зависит от разметки.
        Width = Metrics.PowerSide;
        Height = Metrics.PowerSide;

        // Курсор ставим один раз: за пределами круга HitTestCore нас не
        // возвращает, значит и курсор там уже не наш.
        Cursor = Cursors.Hand;

        // Пунктирная рамка фокуса рисуется по прямоугольнику элемента и вокруг
        // круглой кнопки читается как поломка. Состояние и так видно по кольцу.
        FocusVisualStyle = null;

        Retune();
    }

    // ------------------------------------------------------------------
    // Состояние
    // ------------------------------------------------------------------
    public static readonly DependencyProperty StateProperty = DependencyProperty.Register(
        nameof(State), typeof(string), typeof(PowerButton),
        new FrameworkPropertyMetadata(Idle, FrameworkPropertyMetadataOptions.AffectsRender, OnStateChanged));

    public string State
    {
        get { return (string)GetValue(StateProperty); }
        set { SetValue(StateProperty, value); }
    }

    /// <summary>Доля перехода из <see cref="_prevState"/> в <see cref="State"/>.</summary>
    private static readonly DependencyProperty FadeProperty = DependencyProperty.Register(
        "Fade", typeof(double), typeof(PowerButton),
        new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender));

    /// <summary>Оборот бегущей дуги, 0…1.</summary>
    private static readonly DependencyProperty SpinProperty = DependencyProperty.Register(
        "Spin", typeof(double), typeof(PowerButton),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    /// <summary>Фаза дыхания, 0…1.</summary>
    private static readonly DependencyProperty BreathProperty = DependencyProperty.Register(
        "Breath", typeof(double), typeof(PowerButton),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    private static void OnStateChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        ((PowerButton)d).StartFade((string)e.OldValue);
    }

    private void StartFade(string from)
    {
        if (from == State)
        {
            return;
        }

        _prevState = from;

        // Кольца разных состояний — разные фигуры, поэтому смена идёт
        // растворением одного в другое. Толщину и пунктир между собой не
        // «доанимировать»: пунктир не интерполируется вовсе, а рывок с 3 на 5
        // читался бы как подёргивание.
        var anim = new DoubleAnimation(0.0, 1.0, new Duration(TimeSpan.FromMilliseconds(Metrics.StateChangeMs)));
        anim.EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut };
        anim.Completed += (sender, args) =>
        {
            // Прерванная анимация тоже присылает Completed; её сообщение
            // оборвало бы уже идущий следующий переход на полпути.
            if (!ReferenceEquals(_fadeAnim, anim))
            {
                return;
            }

            _prevState = State;
            Retune();
        };

        _fadeAnim = anim;
        BeginAnimation(FadeProperty, anim);
        Retune();
    }

    /// <summary>Держим включёнными только те бесконечные анимации, что видны.</summary>
    private void Retune()
    {
        string state = State;
        bool fading = _prevState != state;

        SetSpinning(state == Connecting || (fading && _prevState == Connecting));
        SetBreathing(state == Idle || (fading && _prevState == Idle));
    }

    private void SetSpinning(bool on)
    {
        // Перезапуск сбросил бы фазу, и дуга прыгнула бы на начало.
        if (on == _spinning)
        {
            return;
        }

        _spinning = on;
        BeginAnimation(SpinProperty, on ? Loop(Metrics.PowerSpinSeconds) : null);
    }

    private void SetBreathing(bool on)
    {
        if (on == _breathing)
        {
            return;
        }

        _breathing = on;
        BeginAnimation(BreathProperty, on ? Loop(Metrics.PowerBreathSeconds) : null);
    }

    /// <summary>Ровный ход 0→1 за seconds, по кругу. Частоту кадров выбирает композитор.</summary>
    private static DoubleAnimation Loop(double seconds)
    {
        var anim = new DoubleAnimation(0.0, 1.0, new Duration(TimeSpan.FromSeconds(seconds)));
        anim.RepeatBehavior = RepeatBehavior.Forever;
        return anim;
    }

    // ------------------------------------------------------------------
    // Мышь
    // ------------------------------------------------------------------
    /// <summary>
    /// Нажимается ровно круг, а не квадрат вокруг него. Заодно этим же
    /// считается наведение: IsMouseOver в WPF идёт от того же теста, и курсор
    /// в углу виджета — за сотню единиц от кольца — заливку не зажигает.
    /// </summary>
    protected override HitTestResult? HitTestCore(PointHitTestParameters hitTestParameters)
    {
        double radius = RenderSize.Width / 2 - RingOf(State).Width;
        var d = hitTestParameters.HitPoint - new Point(RenderSize.Width / 2, RenderSize.Height / 2);
        if (d.LengthSquared > radius * radius)
        {
            return null;
        }

        return new PointHitTestResult(this, hitTestParameters.HitPoint);
    }

    protected override void OnMouseEnter(MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        InvalidateVisual();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        InvalidateVisual();
    }

    // ------------------------------------------------------------------
    // Отрисовка
    // ------------------------------------------------------------------
    protected override void OnRender(DrawingContext dc)
    {
        double w = RenderSize.Width;
        double h = RenderSize.Height;
        if (w <= 0 || h <= 0)
        {
            return;
        }

        string state = State;
        string prev = _prevState;
        double fade = (double)GetValue(FadeProperty);
        bool fading = fade < 1.0 && prev != state;

        double prevW = RingOf(prev).Width;
        double curW = RingOf(state).Width;
        // Шайба одна на все состояния, меняется только её кромка вместе с
        // толщиной кольца — поэтому рисуем её один раз и по промежуточной
        // толщине: иначе на переходе радиус прыгал бы на две единицы.
        PaintDisc(dc, fading ? prevW + (curW - prevW) * fade : curW);

        if (fading)
        {
            dc.PushOpacity(1.0 - fade);
            PaintState(dc, prev);
            dc.Pop();
            dc.PushOpacity(fade);
            PaintState(dc, state);
            dc.Pop();
        }
        else
        {
            PaintState(dc, state);
        }
    }

    private void PaintDisc(DrawingContext dc, double inset)
    {
        double side = RenderSize.Width;
        var box = Deflate(inset);
        if (box.Width <= 0 || box.Height <= 0)
        {
            return;
        }

        // Свет сверху: центр перехода смещён вверх, к краям шайба уходит в фон.
        // При наведении заливка светлеет на ступень — единственная реакция на
        // мышь, подложек и рамок у кнопки нет.
        var grad = new RadialGradientBrush(
            Palette.Parse(IsMouseOver ? Palette.Stroke : Palette.SurfaceHi),
            Palette.Parse(Palette.Surface));
        grad.MappingMode = BrushMappingMode.Absolute;
        grad.Center = new Point(
            box.Left + box.Width * Metrics.PowerLightX,
            box.Top + box.Height * Metrics.PowerLightY);
        // При абсолютной привязке GradientOrigin не наследует Center и остался
        // бы в точке (0.5, 0.5) — то есть в углу шайбы.
        grad.GradientOrigin = grad.Center;
        grad.RadiusX = side * Metrics.PowerLightRadius;
        grad.RadiusY = side * Metrics.PowerLightRadius;
        grad.Freeze();

        dc.DrawEllipse(grad, null, Centre(box), box.Width / 2, box.Height / 2);

        // Кромка шайбы. Тонкая и заметно меньше кольца состояния — спутать их
        // нельзя, а плоский круг она превращает в предмет.
        double edge = side * Metrics.PowerEdgeInset;
        var lip = Rect.Inflate(box, -edge, -edge);
        if (lip.Width <= 0 || lip.Height <= 0)
        {
            return;
        }

        var pen = new Pen(Palette.StrokeBrush, Metrics.Hairline);
        pen.Freeze();
        dc.DrawEllipse(null, pen, Centre(lip), lip.Width / 2, lip.Height / 2);
    }

    private void PaintState(DrawingContext dc, string state)
    {
        var ring = RingOf(state);
        var box = Deflate(ring.Width);
        if (box.Width <= 0 || box.Height <= 0)
        {
            return;
        }

        var centre = Centre(box);
        double rx = box.Width / 2;
        double ry = box.Height / 2;

        if (state == Connecting)
        {
            // Тусклое кольцо целиком плюс яркая дуга, бегущая по нему.
            dc.PushOpacity(Metrics.PowerTrackOpacity);
            dc.DrawEllipse(null, Stroke(ring.Brush, ring.Width, false, false), centre, rx, ry);
            dc.Pop();

            double turn = (double)GetValue(SpinProperty);
            // Углы оставлены в системе Qt (против часовой стрелки), их переводит
            // в точки Arc(); так строка сверяется с ui/widgets.py.
            dc.DrawGeometry(null, Stroke(ring.Brush, ring.Width, false, true),
                Arc(centre, rx, ry, 90 - turn * 360, -Metrics.PowerArcDegrees));
        }
        else if (state == Idle)
        {
            // Дыхание нужно затем, что в простое окно выглядит замёрзшим: ни
            // одного движущегося пикселя, и непонятно, живо ли приложение.
            // Меняется только яркость — форма кольца, по которой состояния и
            // различаются, остаётся прежней.
            double t = (double)GetValue(BreathProperty);
            // Косинус даёт плавный разворот на обоих концах: без него вдох и
            // выдох стыкуются рывком.
            double wave = (1 - Math.Cos(2 * Math.PI * t)) / 2;
            double low = Metrics.PowerBreathLow;

            dc.PushOpacity(low + (1 - low) * wave);
            dc.DrawEllipse(null, Stroke(ring.Brush, ring.Width, false, false), centre, rx, ry);
            dc.Pop();
        }
        else
        {
            dc.DrawEllipse(null, Stroke(ring.Brush, ring.Width, ring.Dashed, false), centre, rx, ry);
        }

        // При «подключено» знак рисуется фирменным градиентом, в остальных
        // состояниях — цветом состояния.
        double mark = RenderSize.Width * MarkFraction;
        var markBox = new Rect(
            (RenderSize.Width - mark) / 2,
            (RenderSize.Height - mark) / 2,
            mark, mark);
        Brandmark.Paint(dc, markBox, state == Connected ? null : ring.Brush);
    }

    private static Pen Stroke(Brush brush, double width, bool dashed, bool roundCap)
    {
        var pen = new Pen(brush, width);
        if (dashed)
        {
            pen.DashStyle = new DashStyle(DashPattern, 0);
            // Пунктир Qt рисовался колпачком SquareCap (умолчание QPen): каждый
            // штрих выходит на полтолщины длиннее заданных трёх, а просвет на
            // столько же короче. У WPF DashCap по умолчанию тоже Square, но
            // пишем явно — иначе правка колпачков линии рядом легко утащит за
            // собой и колпачок штриха, и ритм пунктира уедет.
            pen.DashCap = PenLineCap.Square;
        }

        if (roundCap)
        {
            pen.StartLineCap = PenLineCap.Round;
            pen.EndLineCap = PenLineCap.Round;
        }

        pen.Freeze();
        return pen;
    }

    /// <summary>Дуга по углам Qt: θ против часовой стрелки при оси Y вниз.</summary>
    private static Geometry Arc(Point centre, double rx, double ry, double startQt, double spanQt)
    {
        var geo = new StreamGeometry();
        using (var ctx = geo.Open())
        {
            ctx.BeginFigure(OnEllipse(centre, rx, ry, startQt), false, false);
            ctx.ArcTo(
                OnEllipse(centre, rx, ry, startQt + spanQt),
                new Size(rx, ry), 0,
                Math.Abs(spanQt) > 180,
                // Рост θ у Qt виден как обход против часовой стрелки.
                spanQt < 0 ? SweepDirection.Clockwise : SweepDirection.Counterclockwise,
                true, false);
        }

        geo.Freeze();
        return geo;
    }

    private static Point OnEllipse(Point centre, double rx, double ry, double angleDeg)
    {
        double a = angleDeg * Math.PI / 180.0;
        return new Point(centre.X + rx * Math.Cos(a), centre.Y - ry * Math.Sin(a));
    }

    private Rect Deflate(double inset)
    {
        return new Rect(
            inset, inset,
            Math.Max(0, RenderSize.Width - 2 * inset),
            Math.Max(0, RenderSize.Height - 2 * inset));
    }

    private static Point Centre(Rect box)
    {
        return new Point(box.Left + box.Width / 2, box.Top + box.Height / 2);
    }

    private static Ring RingOf(string? state)
    {
        Ring ring;
        // Неизвестное состояние рисуем как простой: уронить окно на отрисовке
        // из-за опечатки в строке — худшее, что тут можно сделать.
        if (state == null || !Rings.TryGetValue(state, out ring))
        {
            ring = Rings[Idle];
        }

        return ring;
    }

    private static DoubleCollection MakeDashPattern()
    {
        var dashes = new DoubleCollection();
        dashes.Add(3);
        dashes.Add(3);
        dashes.Freeze();
        return dashes;
    }

    private readonly struct Ring
    {
        public Ring(Brush brush, double width, bool dashed)
        {
            Brush = brush;
            Width = width;
            Dashed = dashed;
        }

        public Brush Brush { get; }

        public double Width { get; }

        public bool Dashed { get; }
    }
}
