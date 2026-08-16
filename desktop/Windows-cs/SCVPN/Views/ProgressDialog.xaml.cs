using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using SCVPN.Theme;

namespace SCVPN.Views;

/// <summary>
/// Окно загрузки ядра: текущий шаг, полоса и отмена. Замена QProgressDialog
/// из ui/main_window.py (_progress_dialog / _show_progress).
///
/// Полоса стартует бегущей. Кто умеет считать байты, переведёт её в проценты
/// первым же <see cref="Report"/>; кто не умеет — оставит бегущей до конца, и
/// это честно.
///
/// Кнопка отмены здесь появилась, а в Qt-версии её не было намеренно: там
/// прервать можно было только сам поток, а он сидел в чтении сокета, и кнопка,
/// которая закрывает окно, но не останавливает загрузку, врала бы про то, что
/// она делает. Здесь загрузка идёт по CancellationToken, поэтому отмена
/// настоящая — но окно по нажатию не закрывается: оно закроется, когда
/// загрузка действительно остановится и вызывающий позовёт <see cref="Finish"/>.
/// </summary>
public partial class ProgressDialog : Window
{
    /// <summary>
    /// Высота полосы. В Metrics такого числа нет: полоса есть только в этом
    /// окне, а общей шкалы толщин у интерфейса нет.
    /// </summary>
    private const double BarHeight = 6;

    /// <summary>Доля полосы: −1 — размер неизвестен, полоса бегущая.</summary>
    private double _fraction = -1;

    /// <summary>Закрытие после <see cref="Finish"/> — не отмена.</summary>
    private bool _finished;

    /// <summary>Бегущая анимация уже запущена — второй раз её заводить нельзя.</summary>
    private bool _running;

    public ProgressDialog(string text, Window? owner)
    {
        InitializeComponent();

        Label.Text = text;

        Root.Margin = new Thickness(Metrics.SheetPadH, Metrics.SheetPadV,
                                    Metrics.SheetPadH, Metrics.SheetPadV);
        Track.Height = BarHeight;
        Track.Margin = new Thickness(0, Metrics.SheetGap, 0, 0);
        Counter.Margin = new Thickness(0, Metrics.SubstatusTop, 0, 0);
        CancelButton.Margin = new Thickness(0, Metrics.SheetGap, 0, 0);

        // Owner ставится только у показанного окна, иначе WPF бросает
        // исключение прямо здесь.
        if (owner != null && owner.IsLoaded)
        {
            Owner = owner;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            // Qt-версия открывала окно с Qt.WindowModal — модальным к главному
            // окну, но не к приложению. В WPF такой модальности нет: ShowDialog
            // блокирует всё приложение и вдобавок не вернёт управление до
            // закрытия, а загрузка идёт здесь же. Поэтому окно обычное, а
            // главное на время загрузки не принимает ввод — ровно то, что
            // делал Qt.
            owner.IsEnabled = false;
            Closed += (_, _) => owner.IsEnabled = true;
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }

        // Показываем сразу. Qt держал окно скрытым первые четыре секунды (пока
        // не сняли minimumDuration) — ровно те, ради которых окно и заводили:
        // на быстром канале ядро успевает скачаться, и человек не видит вообще
        // ничего.
        Show();
    }

    /// <summary>Нажали отмену (или закрыли окно, не дождавшись конца).</summary>
    public bool Cancelled { get; private set; }

    /// <summary>
    /// Отмену просят — пора отменить CancellationToken загрузки. Событие
    /// приходит в потоке интерфейса.
    /// </summary>
    public event Action? CancelRequested;

    /// <summary>Текущий шаг. Зовётся из потока загрузки.</summary>
    public void SetText(string text)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.InvokeAsync(() => SetText(text));
            return;
        }

        Label.Text = text;
    }

    /// <summary>
    /// Продвинуть полосу. total = 0 — размер неизвестен, полоса остаётся
    /// бегущей.
    /// </summary>
    public void Report(long got, long total)
    {
        if (!Dispatcher.CheckAccess())
        {
            // Загрузчик шлёт байты из своего потока. InvokeAsync, а не Invoke:
            // очередь диспетчера порядок сохраняет, а ждать отрисовки ради
            // счётчика загрузке незачем.
            Dispatcher.InvokeAsync(() => Report(got, total));
            return;
        }

        // Считаем в килобайтах — как и Qt-версия: там байты переполняли int32,
        // которым QProgressDialog мерил прогресс, уже на двух гигабайтах.
        // Здесь переполняться нечему, но единица осталась подписью под полосой.
        long gotKb = got / 1024;
        if (total <= 0)
        {
            // Сервер не прислал Content-Length. Проценты от неизвестного целого
            // не рисуем — только сколько уже пришло.
            Counter.Text = gotKb + " КБ";
            return;
        }

        Counter.Text = gotKb + " / " + total / 1024 + " КБ";
        _fraction = Math.Clamp((double)got / total, 0, 1);
        Redraw();
    }

    /// <summary>Загрузка кончилась (успехом, ошибкой или отменой) — закрыть окно.</summary>
    public void Finish()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.InvokeAsync(Finish);
            return;
        }

        _finished = true;
        Close();
    }

    // ------------------------------------------------------------------

    protected override void OnClosed(EventArgs e)
    {
        // Бегущая анимация повторяется вечно, и часы закрытого окна остались бы
        // в менеджере времени WPF: окно не собралось бы сборщиком мусора, а
        // отрисовка продолжала бы просыпаться на каждый кадр до конца работы
        // приложения. Ядро скачивают по нескольку раз за сеанс — окон
        // накопится столько же.
        FillShift.BeginAnimation(TranslateTransform.XProperty, null);
        base.OnClosed(e);
    }

    private void OnCancel(object sender, RoutedEventArgs e)
    {
        RequestCancel();
    }

    private void OnClosing(object sender, CancelEventArgs e)
    {
        // Закрыли крестиком, не дождавшись конца, — это тоже отмена. Держать
        // окно силой нельзя: закрытая крестиком загрузка иначе продолжалась бы
        // втайне от того, кто её только что прекратил.
        if (!_finished)
        {
            RequestCancel();
        }
    }

    private void RequestCancel()
    {
        if (Cancelled)
        {
            return;
        }

        Cancelled = true;
        // Кнопка гаснет, а окно остаётся: загрузка останавливается не мгновенно,
        // и закрыть окно раньше значило бы соврать, что всё уже прекратилось.
        CancelButton.IsEnabled = false;
        CancelRequested?.Invoke();
    }

    private void OnTrackResized(object sender, SizeChangedEventArgs e)
    {
        // Ширина полосы известна только после разметки, а бегущая анимация
        // ездит от края до края — значит, при каждой смене ширины её надо
        // пересчитать заново.
        _running = false;
        Redraw();
    }

    private void Redraw()
    {
        double width = Track.ActualWidth;
        if (width <= 0)
        {
            return;
        }

        if (_fraction >= 0)
        {
            FillShift.BeginAnimation(TranslateTransform.XProperty, null);
            FillShift.X = 0;
            Fill.Width = width * _fraction;
            _running = false;
            return;
        }

        if (_running)
        {
            return;
        }

        _running = true;
        // Бегущий кусок такой же длины и с таким же ходом, что и бегущая дуга
        // кнопки питания: в окне это одно и то же «идёт работа», и разные
        // скорости читались бы как разные процессы.
        Fill.Width = width * (Metrics.PowerArcDegrees / 360.0);
        FillShift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation
        {
            From = -Fill.Width,
            To = width,
            Duration = TimeSpan.FromSeconds(Metrics.PowerSpinSeconds),
            RepeatBehavior = RepeatBehavior.Forever,
        });
    }
}
