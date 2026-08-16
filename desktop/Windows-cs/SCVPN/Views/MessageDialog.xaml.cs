using System.Windows;
using System.Windows.Input;
using SCVPN.Theme;

namespace SCVPN.Views;

/// <summary>
/// Собственные вопросы и сообщения — вместо системного MessageBox.
///
/// Системный MessageBox нарисован для светлой темы и в чёрно-белой гамме
/// приложения выглядит чужим окном из другой программы. Qt-версия боролась с
/// этим наполовину: окно она красила таблицей стилей, а значки подменяла своим
/// QProxyStyle (см. _glyph_icon в ui/theme.py). В WPF красить нечего — окно
/// системное целиком, — поэтому оно нарисовано здесь заново, а значки
/// переехали один в один: кольцо цвета Dim, знак цвета Text.
///
/// Снаружи класс используется как набор статических методов
/// (<c>MessageDialog.Question(...)</c>); окном он быть обязан, потому что
/// рисует сам себя, а конструктор поэтому закрытый.
/// </summary>
public partial class MessageDialog : Window
{
    /// <summary>
    /// Сторона значка. Qt рисовал его в пиксмап 64×64 и отдавал QMessageBox, а
    /// тот масштабировал картинку под свой PM_MessageBoxIconSize; здесь мы
    /// рисуем вектором сразу в нужном размере. Пропорции кольца и знака заданы
    /// в долях стороны, поэтому на вид размера они не меняют. В Metrics числа
    /// нет: значок есть только в этом окне.
    /// </summary>
    private const double IconSide = 48;

    // Доли стороны — из _glyph_icon в ui/theme.py, менять только вместе с ним:
    // отступ кольца от края, толщина кольца, кегль знака.
    private const double RingInset = 0.08;
    private const double RingWidth = 0.045;
    private const double GlyphScale = 0.56;

    /// <param name="glyph">null — значка нет вовсе (у QInputDialog его тоже не было).</param>
    /// <param name="secondary">null — одна кнопка: сообщению отвечать нечем.</param>
    /// <param name="initial">null — поля ввода нет.</param>
    private MessageDialog(Window? owner, string title, string text, string? glyph,
                          string primary, string? secondary, string? initial)
    {
        InitializeComponent();

        Title = title;
        Message.Text = text;

        // Поля окна общие у всех окон поверх главного: разные отступы заметны,
        // когда окна открывают подряд.
        Root.Margin = new Thickness(Metrics.SheetPadH, Metrics.SheetPadV,
                                    Metrics.SheetPadH, Metrics.SheetPadV);

        if (glyph == null)
        {
            IconBox.Visibility = Visibility.Collapsed;
        }
        else
        {
            IconBox.Width = IconSide;
            IconBox.Height = IconSide;
            Ring.Width = IconSide * (1 - 2 * RingInset);
            Ring.Height = Ring.Width;
            Ring.StrokeThickness = IconSide * RingWidth;
            Glyph.Text = glyph;
            Glyph.FontSize = IconSide * GlyphScale;
            Message.Margin = new Thickness(Metrics.SheetGap, 0, 0, 0);
        }

        if (initial != null)
        {
            Input.Visibility = Visibility.Visible;
            Input.Margin = new Thickness(0, Metrics.SheetGap, 0, 0);
            Input.BorderThickness = new Thickness(Metrics.StrokeWidth);
            Input.Text = initial;
            // Всё выделено: чаще всего подставленное имя переписывают целиком,
            // а не дополняют.
            Input.SelectAll();
        }

        PrimaryButton.Content = primary;
        PrimaryButton.Margin = new Thickness(Metrics.SheetGap, 0, 0, 0);
        ButtonRow.Margin = new Thickness(0, Metrics.SheetGap, 0, 0);
        if (secondary != null)
        {
            SecondaryButton.Content = secondary;
            SecondaryButton.Visibility = Visibility.Visible;
        }

        // Owner ставится только у показанного окна, иначе WPF бросает
        // исключение прямо здесь. Без владельца окно некуда центрировать —
        // тогда по экрану.
        if (owner != null && owner.IsLoaded)
        {
            Owner = owner;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
    }

    // ------------------------------------------------------------------
    // Публичный вид: четыре сообщения и один ввод строки
    // ------------------------------------------------------------------

    /// <summary>Вопрос «да/нет». true — ответили «Да».</summary>
    public static bool Question(Window? owner, string text, string title = "SCVPN")
    {
        return Run(owner, title, text, "?", "Да", "Нет");
    }

    public static void Info(Window? owner, string text, string title = "SCVPN")
    {
        Run(owner, title, text, "i", "ОК", null);
    }

    public static void Warning(Window? owner, string text, string title = "SCVPN")
    {
        Run(owner, title, text, "!", "ОК", null);
    }

    public static void Error(Window? owner, string text, string title = "SCVPN")
    {
        Run(owner, title, text, "✕", "ОК", null);
    }

    /// <summary>
    /// Ввод строки — замена QInputDialog.getText. null — отменили; пустая
    /// строка означает, что нажали «ОК» с пустым полем, и это разные ответы:
    /// вызывающий сам решает, чем заменить пустое имя.
    /// </summary>
    public static string? Prompt(Window? owner, string title, string label, string initial = "")
    {
        var dialog = new MessageDialog(owner, title, label, null, "ОК", "Отмена", initial);
        dialog.Loaded += (_, _) => dialog.Input.Focus();
        return dialog.ShowDialog() == true ? dialog.Input.Text : null;
    }

    private static bool Run(Window? owner, string title, string text, string glyph,
                            string primary, string? secondary)
    {
        return new MessageDialog(owner, title, text, glyph, primary, secondary, null)
            .ShowDialog() == true;
    }

    private void OnPrimary(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        // Esc закрывает и сообщение с единственной кнопкой — так вёл себя
        // QMessageBox. Само по себе IsCancel этого не даёт: у сообщения вторая
        // кнопка скрыта, а до скрытой кнопки AccessKeyManager нажатие не
        // доносит (он пропускает всё невидимое и недоступное).
        if (e.Key == Key.Escape && SecondaryButton.Visibility != Visibility.Visible)
        {
            e.Handled = true;
            // Close(), а не DialogResult: ShowDialog вернёт null, и это тот же
            // ответ «отказались», что и у кнопки отмены.
            Close();
        }
    }
}
