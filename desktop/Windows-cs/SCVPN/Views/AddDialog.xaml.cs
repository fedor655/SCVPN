using System.Windows;
using System.Windows.Input;
using SCVPN.Theme;

namespace SCVPN.Views;

/// <summary>
/// Добавление сервера или подписки: вставить ссылку или отсканировать QR.
///
/// Одно поле на оба случая — тип определяется по самой строке, а не выбором
/// пользователя: ссылку сервера парсер узнаёт, всё остальное с http(s)
/// считается подпиской. Спрашивать «это ссылка или подписка?» значило бы
/// перекладывать на человека то, что программа выясняет сама.
///
/// Порт ui/add_dialog.py. Открывать через <c>ShowDialog()</c>.
/// </summary>
public partial class AddDialog : Window
{
    /// <summary>
    /// Высота поля ввода. Число из ui/add_dialog.py: три строки моноширинного
    /// текста — столько, чтобы ссылка целиком была видна без прокрутки. В
    /// Metrics его нет, потому что нужно оно ровно здесь.
    /// </summary>
    private const double InputHeight = 78;

    public AddDialog()
    {
        InitializeComponent();

        // Ширина и поля общие у всех окон поверх главного: разные ширины
        // заметны, когда окна открывают подряд.
        Root.Margin = new Thickness(Metrics.SheetPadH, Metrics.SheetPadV,
                                    Metrics.SheetPadH, Metrics.SheetPadV);
        Caption.Margin = new Thickness(0, 0, 0, Metrics.SheetGap);
        InputHost.Margin = new Thickness(0, 0, 0, Metrics.SheetGap);

        Input.Height = InputHeight;
        Input.BorderThickness = new Thickness(Metrics.StrokeWidth);
        // Поле внутри поля ввода равно скруглению панели: у самого угла текст
        // иначе поджимается к дуге. Отдельного числа под это в Metrics нет.
        Input.Padding = new Thickness(Metrics.BoxCorner);
        // Подсказка встаёт ровно туда, где начнётся текст: рамка плюс поле.
        Placeholder.Margin = new Thickness(Metrics.BoxCorner + Metrics.StrokeWidth,
                                          Metrics.BoxCorner + Metrics.StrokeWidth, 0, 0);

        OkButton.Margin = new Thickness(Metrics.SheetGap, 0, 0, 0);
    }

    /// <summary>Введённая строка. Пусто — значит, отменили.</summary>
    public string Result { get; private set; } = string.Empty;

    private void OnInputChanged(object sender, RoutedEventArgs e)
    {
        Placeholder.Visibility = Input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnScan(object sender, RoutedEventArgs e)
    {
        var scanner = new QrScannerDialog();
        // Owner ставится только у показанного окна, иначе WPF бросает
        // исключение прямо здесь.
        if (IsLoaded)
        {
            scanner.Owner = this;
        }

        scanner.ShowDialog();
        if (scanner.Text.Length == 0)
        {
            return;
        }

        Input.Text = scanner.Text;
        // Сразу не закрываем: пусть видно, что именно распозналось —
        // QR может оказаться не тем, что человек ожидал.
        Input.Focus();
        Input.CaretIndex = Input.Text.Length;
    }

    private void OnAccept(object sender, RoutedEventArgs e)
    {
        Accept();
    }

    private void Accept()
    {
        Result = Input.Text.Trim();
        if (Result.Length == 0)
        {
            // Пустое поле — не ответ: окно остаётся открытым.
            return;
        }

        DialogResult = true;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        // В многострочном поле Enter вставляет перенос, поэтому подтверждаем
        // по Ctrl+Enter — иначе кнопку «Добавить» пришлось бы искать мышью.
        if ((e.Key == Key.Return || e.Key == Key.Enter)
            && (Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            e.Handled = true;
            Accept();
        }
    }
}
