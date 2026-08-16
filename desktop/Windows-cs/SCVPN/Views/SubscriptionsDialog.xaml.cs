using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QRCoder;
using SCVPN.Core;
using SCVPN.Theme;

namespace SCVPN.Views;

/// <summary>
/// Экран подписок: что это за подписка, сколько осталось и как ею поделиться.
///
/// Всё, что показано, приходит от панели в заголовках ответа (см.
/// <see cref="SubscriptionInfo"/>) — приложение ничего не досчитывает. Дата
/// «добавлена» — единственная местная: даты активации панели не присылают,
/// поэтому она честно подписана как момент добавления подписки в SCVPN, а не
/// как начало оплаченного периода.
///
/// В отличие от Qt-версии окно показывает сразу все подписки карточками:
/// прежде главное окно сначала спрашивало QInputDialog'ом, какую открыть, и
/// выбор из одного пункта был лишним шагом.
/// </summary>
public partial class SubscriptionsDialog : Window
{
    // Числа, которых нет в Metrics: они живут только на этом экране. В
    // Qt-версии они стояли прямо в коде диалога — переносим их сюда, а не в
    // общую шкалу, чтобы не выдавать частный случай за метрику всего клиента.
    /// <summary>Заголовок карточки: шкала Metrics обрывается на 13, а здесь нужен шаг крупнее.</summary>
    private const double TitleSize = 14;
    /// <summary>Между блоками карточки и между колонкой ссылки и QR.</summary>
    private const double BlockGap = 14;
    /// <summary>Между строками статистики.</summary>
    private const double StatGap = 7;
    /// <summary>Просвет внутри колонок — такой же, каким его давал Qt по умолчанию.</summary>
    private const double InnerGap = 6;
    /// <summary>Поля в рамке объявления панели и в рамке со ссылкой.</summary>
    private const double NotePad = 10;
    private const double LinkPad = 8;
    /// <summary>Полоса расхода трафика.</summary>
    private const double BarHeight = 6;
    private const double BarRadius = 3;
    /// <summary>Видимый минимум заполнения: иначе первые проценты не видно вовсе.</summary>
    private const double BarMinFill = 6;
    /// <summary>Порог, после которого полоса перестаёт быть акцентной: лимит на исходе.</summary>
    private const double BarAlarmRatio = 0.9;
    /// <summary>Сторона QR-кода.</summary>
    private const double QrSide = 190;

    private readonly Profiles _profiles;

    /// <summary>Нажали «Обновить» на подписке. Обновляет её главное окно, не диалог.</summary>
    public event Func<Subscription, Task>? UpdateRequested;

    /// <summary>Удалили подписку целиком.</summary>
    public event Action<Subscription>? DeleteRequested;

    public SubscriptionsDialog(Profiles profiles)
    {
        _profiles = profiles;
        InitializeComponent();

        FontFamily = new FontFamily(Metrics.UiFont);
        Root.Margin = new Thickness(Metrics.SheetPadH, Metrics.SheetPadV, Metrics.SheetPadH, Metrics.SheetPadV);
        FooterDivider.Margin = new Thickness(0, BlockGap, 0, BlockGap);

        // Высоту окно берёт по содержимому, но подписок бывает несколько, и без
        // потолка окно выросло бы за край экрана — тогда «Закрыть» оказывается
        // под панелью задач и окно нечем закрыть мышью.
        MaxHeight = SystemParameters.WorkArea.Height * 0.9;

        Refresh();
    }

    /// <summary>Перерисовать после того, как главное окно обновило данные.</summary>
    public void Refresh()
    {
        // Главное окно ходит в сеть в фоне и может позвать нас из чужого потока.
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(Refresh);
            return;
        }

        Cards.Children.Clear();

        if (_profiles.Subscriptions.Count == 0)
        {
            // Тот же текст, что показывало главное окно, когда подписок нет.
            Cards.Children.Add(new TextBlock
            {
                Text = "Подписок нет.\nДобавь кнопкой + вверху.",
                Foreground = Palette.DimBrush,
                FontSize = Metrics.FsBody,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }

        for (int i = 0; i < _profiles.Subscriptions.Count; i++)
        {
            if (i > 0) Cards.Children.Add(Divider(BlockGap, BlockGap));
            Cards.Children.Add(BuildCard(_profiles.Subscriptions[i]));
        }
    }

    // ------------------------------------------------------------------
    // Карточка подписки
    // ------------------------------------------------------------------

    // Возвращаемый тип у всех сборщиков — FrameworkElement, а не UIElement:
    // Gap() задаёт полям Margin, а Margin появляется только у FrameworkElement.
    private FrameworkElement BuildCard(Subscription sub)
    {
        SubscriptionInfo info = sub.Info;
        var card = new StackPanel();

        string headline = info.Title.Length > 0 ? info.Title
            : sub.Name.Length > 0 ? sub.Name
            : "Подписка";
        card.Children.Add(Gap(new TextBlock
        {
            Text = headline,
            Foreground = Palette.TextBrush,
            FontSize = TitleSize,
            FontWeight = FontWeights.Bold,
            TextWrapping = TextWrapping.Wrap,
        }, BlockGap));

        if (info.Account.Length > 0)
        {
            card.Children.Add(Gap(new TextBlock
            {
                Text = info.Account,
                Foreground = Palette.DimBrush,
                FontSize = Metrics.FsBody,
                TextWrapping = TextWrapping.Wrap,
            }, BlockGap));
        }

        if (info.Announce.Length > 0)
        {
            card.Children.Add(Gap(new Border
            {
                Background = Palette.SurfaceHiBrush,
                BorderBrush = Palette.StrokeBrush,
                BorderThickness = new Thickness(Metrics.StrokeWidth),
                CornerRadius = new CornerRadius(Metrics.BoxCorner),
                Padding = new Thickness(NotePad),
                Child = new TextBlock
                {
                    Text = info.Announce,
                    Foreground = Palette.TextBrush,
                    FontSize = Metrics.FsBody,
                    TextWrapping = TextWrapping.Wrap,
                },
            }, BlockGap));
        }

        card.Children.Add(Gap(StatsBlock(sub), BlockGap));
        card.Children.Add(Divider(0, BlockGap));
        card.Children.Add(Gap(LinkBlock(sub), BlockGap));
        card.Children.Add(Divider(0, BlockGap));
        card.Children.Add(CardButtons(sub));
        return card;
    }

    private FrameworkElement StatsBlock(Subscription sub)
    {
        SubscriptionInfo info = sub.Info;
        var box = new StackPanel();

        // --- трафик ---
        if (info.Unlimited)
        {
            box.Children.Add(Gap(Row("Потрачено", SubscriptionInfo.HumanBytes(info.Used)), StatGap));
            box.Children.Add(Gap(Row("Лимит трафика", "безлимит"), StatGap));
        }
        else
        {
            box.Children.Add(Gap(Row("Потрачено",
                SubscriptionInfo.HumanBytes(info.Used) + " из " + SubscriptionInfo.HumanBytes(info.Total)), StatGap));
            box.Children.Add(Gap(TrafficBar(info.UsedRatio), StatGap));
        }
        if (info.Upload != 0 || info.Download != 0)
        {
            box.Children.Add(Gap(Row(
                "  из них отдано / принято",
                SubscriptionInfo.HumanBytes(info.Upload) + " / " + SubscriptionInfo.HumanBytes(info.Download),
                Palette.DimBrush), StatGap));
        }

        // --- срок ---
        DateTime? expires = info.ExpiresAt;
        if (expires is not null)
        {
            // Цветом тревожность не показать — пишем словами.
            int? left = info.DaysLeft;
            string tail = "";
            if (left is not null)
            {
                string days = left.Value.ToString(CultureInfo.InvariantCulture);
                if (left.Value < 0) tail = "  ·  истекла";
                else if (left.Value <= 5) tail = "  ·  осталось " + days + " дн. — скоро истечёт";
                else tail = "  ·  осталось " + days + " дн.";
            }
            // Формат даты фиксированный: в русской локали Windows он тот же, но
            // на английской «dd.MM.yyyy» иначе превратилось бы в «MM/dd/yyyy».
            box.Children.Add(Gap(Row("Действует до",
                expires.Value.ToString("dd.MM.yyyy", CultureInfo.InvariantCulture) + tail), StatGap));
        }
        else
        {
            box.Children.Add(Gap(Row("Действует до", "бессрочно"), StatGap));
        }

        box.Children.Add(Gap(Row("Автообновление", SubscriptionInfo.HumanInterval(info.UpdateInterval)), StatGap));
        box.Children.Add(Gap(Row("Серверов", sub.Servers.Count.ToString(CultureInfo.InvariantCulture)), StatGap));

        if (sub.Added.Length > 0)
            box.Children.Add(Gap(Row("Добавлена в SCVPN", sub.Added, Palette.DimBrush), StatGap));
        if (info.Fetched.Length > 0)
            box.Children.Add(Gap(Row("Данные обновлены", info.Fetched, Palette.DimBrush), StatGap));

        // --- устройства ---
        if (info.Hwid.Count > 0)
        {
            if (info.DeviceLimitReached)
                box.Children.Add(Gap(Row("Устройства", "лимит исчерпан"), StatGap));
            else if (info.Hwid.TryGetValue("x-hwid-limit", out string? limited) && limited == "true")
                box.Children.Add(Gap(Row("Устройства", "есть ограничение", Palette.DimBrush), StatGap));
        }

        // Просвет после последней строки блока лишний: его уже даёт BlockGap.
        if (box.Children.Count > 0 && box.Children[box.Children.Count - 1] is FrameworkElement last)
            last.Margin = new Thickness(0);

        return box;
    }

    /// <summary>Строка «подпись — значение». Значение прижато вправо и выделено весом.</summary>
    private static FrameworkElement Row(string label, string value, Brush? color = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var left = new TextBlock
        {
            Text = label,
            Foreground = Palette.DimBrush,
            FontSize = Metrics.FsBody,
        };
        var right = new TextBlock
        {
            Text = value,
            Foreground = color ?? Palette.TextBrush,
            FontSize = Metrics.FsBody,
            FontWeight = FontWeights.SemiBold,
            TextAlignment = TextAlignment.Right,
            TextWrapping = TextWrapping.Wrap,
        };
        Grid.SetColumn(right, 1);
        grid.Children.Add(left);
        grid.Children.Add(right);
        return grid;
    }

    /// <summary>Полоса расхода лимита.</summary>
    private static FrameworkElement TrafficBar(double ratio)
    {
        var track = new Border
        {
            Height = BarHeight,
            CornerRadius = new CornerRadius(BarRadius),
            Background = Palette.StrokeBrush,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };

        if (ratio > 0)
        {
            // Долю показывает сетка, а не вычисленная ширина: ширина полосы
            // известна только после разметки, а звёздочные колонки делят её сами.
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ratio, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - ratio, GridUnitType.Star) });
            grid.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(BarRadius),
                // Тревогу в чёрно-белой теме показывает не цвет, а потеря
                // акцента: у почти исчерпанного лимита полоса гаснет до Dim.
                Background = ratio < BarAlarmRatio ? Palette.AccentBrush : Palette.DimBrush,
                MinWidth = BarMinFill,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            });
            track.Child = grid;
        }

        return track;
    }

    private FrameworkElement LinkBlock(Subscription sub)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // --- слева: подпись, сама ссылка, кнопки ---
        var left = new StackPanel();
        left.Children.Add(Gap(new TextBlock
        {
            Text = "Ссылка подписки",
            Foreground = Palette.DimBrush,
            FontSize = Metrics.FsBody,
        }, InnerGap));

        // Поле ввода вместо подписи — ради выделения мышью: TextBlock в WPF
        // выделять нечем. Style = null снимает общий стиль темы: рамку и фон
        // рисует Border снаружи, у самого поля их быть не должно.
        var link = new TextBox
        {
            Style = null,
            Text = sub.Url,
            IsReadOnly = true,
            IsReadOnlyCaretVisible = false,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = Palette.TextBrush,
            SelectionBrush = Palette.StrokeBrush,
            FontFamily = new FontFamily(Metrics.MonoFont),
            FontSize = Metrics.FsDetail,
            Padding = new Thickness(0),
        };
        left.Children.Add(Gap(new Border
        {
            Background = Palette.BgBrush,
            BorderBrush = Palette.StrokeBrush,
            BorderThickness = new Thickness(Metrics.StrokeWidth),
            CornerRadius = new CornerRadius(Metrics.BoxCorner),
            Padding = new Thickness(LinkPad),
            Child = link,
        }, InnerGap));

        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        var copy = new Button { Content = "Копировать ссылку" };
        copy.Click += (_, _) => CopyLink(sub);
        buttons.Children.Add(copy);
        if (sub.Info.SupportUrl.Length > 0)
        {
            var support = new Button { Content = "Поддержка" };
            support.Margin = new Thickness(InnerGap, 0, 0, 0);
            support.Click += (_, _) => OpenExternal(sub.Info.SupportUrl);
            buttons.Children.Add(support);
        }
        left.Children.Add(buttons);
        grid.Children.Add(left);

        // --- справа: QR ---
        var qrBox = new StackPanel { Margin = new Thickness(BlockGap, 0, 0, 0) };
        ImageSource? qr = QrImage(sub.Url, QrSide);
        if (qr is not null)
        {
            qrBox.Children.Add(Gap(new Image
            {
                Source = qr,
                Width = QrSide,
                Height = QrSide,
                // Модули должны ложиться на пиксельную сетку: со сглаживанием
                // края клеток размываются и дешёвые сканеры промахиваются.
                SnapsToDevicePixels = true,
            }, InnerGap));
            qrBox.Children.Add(new TextBlock
            {
                Text = "Наведи камерой,\nчтобы перенести на телефон",
                Foreground = Palette.DimBrush,
                FontSize = Metrics.FsDetail,
                TextAlignment = TextAlignment.Center,
                MaxWidth = QrSide,
            });
        }
        else
        {
            qrBox.Children.Add(new TextBlock
            {
                Text = "QR недоступен:\nссылка слишком длинная",
                Foreground = Palette.DimBrush,
                FontSize = Metrics.FsDetail,
                TextAlignment = TextAlignment.Center,
                MaxWidth = QrSide,
            });
        }
        Grid.SetColumn(qrBox, 1);
        grid.Children.Add(qrBox);

        return grid;
    }

    private FrameworkElement CardButtons(Subscription sub)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };

        var refresh = new Button { Content = "Обновить" };
        refresh.Click += (_, _) => RunUpdate(sub);
        row.Children.Add(refresh);

        var delete = new Button { Content = "Удалить подписку" };
        delete.Margin = new Thickness(InnerGap, 0, 0, 0);
        // Приглушённая — удаление не должно читаться как обычное действие.
        delete.Foreground = Palette.DimBrush;
        delete.Click += (_, _) => Delete(sub);
        row.Children.Add(delete);

        return row;
    }

    // ------------------------------------------------------------------
    // Действия
    // ------------------------------------------------------------------

    private void CopyLink(Subscription sub)
    {
        try
        {
            Clipboard.SetText(sub.Url);
        }
        catch (COMException)
        {
            // Буфер держит другое приложение — WPF уже отработал свои попытки.
            MessageDialog.Warning(this, "Буфер обмена занят другим приложением.", "Скопировать");
            return;
        }
        MessageDialog.Info(this, "Ссылка подписки в буфере обмена.", "Скопировано");
    }

    private void OpenExternal(string url)
    {
        try
        {
            // UseShellExecute — единственный способ отдать ссылку браузеру:
            // без него .NET пытается запустить URL как исполняемый файл.
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Win32Exception)
        {
            MessageDialog.Warning(this, "Не удалось открыть ссылку:\n" + url, "Поддержка");
        }
        catch (InvalidOperationException)
        {
            MessageDialog.Warning(this, "Не удалось открыть ссылку:\n" + url, "Поддержка");
        }
    }

    /// <summary>
    /// Обновление ведёт главное окно: у него сеть, лог и профиль на диске.
    /// </summary>
    private async void RunUpdate(Subscription sub)
    {
        Func<Subscription, Task>? handler = UpdateRequested;
        if (handler is null) return;

        // Пока идёт запрос, карточки трогать нельзя: обработчик заменит
        // содержимое подписки прямо в profiles, и второй щелчок ушёл бы по
        // данным, которых уже нет.
        Cards.IsEnabled = false;
        try
        {
            await handler(sub);
        }
        catch (Exception ex)
        {
            // Обработчик асинхронный, а метод — async void: непойманное здесь
            // исключение всплывёт уже вне окна и закроет приложение.
            MessageDialog.Error(this, ex.Message, "Подписка «" + sub.Name + "»");
        }
        finally
        {
            Cards.IsEnabled = true;
            Refresh();
        }
    }

    private void Delete(Subscription sub)
    {
        // Удалить сервер поштучно можно правой кнопкой по строке списка, а всю
        // подписку целиком — только отсюда: иначе её серверы вернулись бы при
        // ближайшем «Обновить».
        string question = "Удалить «" + sub.Name + "» и её "
            + sub.Servers.Count.ToString(CultureInfo.InvariantCulture) + " серверов?";
        if (!MessageDialog.Question(this, question, "Удалить подписку")) return;

        DeleteRequested?.Invoke(sub);
        Refresh();
    }

    // ------------------------------------------------------------------
    // QR-код
    // ------------------------------------------------------------------

    /// <summary>
    /// QR-код ссылки. Рисуем матрицу модулей сами: готовые картинки QRCoder
    /// тянут System.Drawing, а он нам больше нигде не нужен. Так же поступала
    /// и Qt-версия — там причиной был Pillow.
    /// </summary>
    private static ImageSource? QrImage(string text, double side)
    {
        if (text.Length == 0) return null;

        try
        {
            using var generator = new QRCodeGenerator();
            // Уровень M — тот же компромисс между запасом и плотностью, что у
            // qrcode по умолчанию: ссылки подписок длинные.
            using QRCodeData data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
            return Draw(data.ModuleMatrix, side);
        }
        catch (QRCoder.Exceptions.DataTooLongException)
        {
            // Ссылка не влезает ни в одну версию кода — показываем текстом.
            return null;
        }
    }

    private static ImageSource? Draw(List<BitArray> matrix, double side)
    {
        // QRCoder всегда кладёт вокруг кода поле в 4 модуля, Qt-версия рисовала
        // 2 — лишнее поле съедает сторону и делает модули мельче. Срезаем два
        // ряда с каждой стороны, чтобы код остался того же размера, что был.
        const int quietDrop = 2;
        int from = quietDrop;
        int to = matrix.Count - quietDrop;
        int n = to - from;
        if (n <= 0) return null;

        double cell = side / n;
        var group = new DrawingGroup();
        using (DrawingContext dc = group.Open())
        {
            // Код читается надёжнее тёмным по светлому, поэтому поле — Text, а
            // модули — Bg, а не наоборот, как во всём остальном окне.
            dc.DrawRectangle(Palette.TextBrush, null, new Rect(0, 0, side, side));
            for (int y = from; y < to; y++)
            {
                BitArray row = matrix[y];
                for (int x = from; x < to && x < row.Count; x++)
                {
                    if (!row[x]) continue;
                    // +0.5 к размеру, чтобы между модулями не просвечивали щели
                    dc.DrawRectangle(Palette.BgBrush, null,
                        new Rect((x - from) * cell, (y - from) * cell, cell + 0.5, cell + 0.5));
                }
            }
        }

        // Хвосты клеток у правого и нижнего края (см. +0.5 выше) выходят за
        // сторону; без обрезки картинка стала бы чуть больше QrSide и Image
        // ужал бы её, сдвинув модули с пиксельной сетки. Обрезка ставится
        // после Open(): Open() заменяет содержимое группы целиком.
        group.ClipGeometry = new RectangleGeometry(new Rect(0, 0, side, side));

        var image = new DrawingImage(group);
        image.Freeze();
        return image;
    }

    // ------------------------------------------------------------------
    // Мелочи разметки
    // ------------------------------------------------------------------

    /// <summary>Просвет под элементом: у StackPanel его задают полями детей.</summary>
    private static T Gap<T>(T element, double bottom) where T : FrameworkElement
    {
        element.Margin = new Thickness(0, 0, 0, bottom);
        return element;
    }

    private static FrameworkElement Divider(double top, double bottom)
    {
        return new Border
        {
            Height = Metrics.Hairline,
            Background = Palette.StrokeBrush,
            Margin = new Thickness(0, top, 0, bottom),
        };
    }
}
