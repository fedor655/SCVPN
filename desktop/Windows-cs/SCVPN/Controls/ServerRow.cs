using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using SCVPN.Theme;

namespace SCVPN.Controls;

/// <summary>
/// Одна строка списка серверов либо заголовок раздела.
///
/// Строка списка плоская: маркер выбора, имя, под ним адрес, справа колонка
/// пинга. Карточек нет — строки разделяет волосяная линия, поэтому список
/// весит меньше кнопки питания, единственного объёмного элемента окна. Выбор
/// показывается маркером слева и яркостью имени, а не обводкой: разница между
/// рамкой в 1 и 1.5 единицы того же белого на чёрном почти не читалась.
///
/// Сама отрисовка живёт в шаблоне строки списка (Theme.xaml): состояния
/// «выбрана», «под курсором», «нажата» ListBoxItem раздаёт сам, и повторять их
/// в собственном элементе было бы длиннее. Здесь — только то, что шаблону
/// нужно показать.
/// </summary>
public sealed class ServerRow : INotifyPropertyChanged
{
    private object? _ping;
    private bool _isLast;

    private ServerRow(Core.Server? server, bool isSection, string title, string subtitle)
    {
        Server = server;
        IsSection = isSection;
        Title = title;
        Subtitle = subtitle;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>null у заголовка раздела.</summary>
    public Core.Server? Server { get; }

    public bool IsSection { get; }

    /// <summary>Имя сервера либо текст заголовка раздела.</summary>
    public string Title { get; }

    /// <summary>«протокол · адрес:порт». У заголовка раздела пусто.</summary>
    public string Subtitle { get; }

    /// <summary>
    /// null — не мерили (показываем «—»), false — не ответил, int — миллисекунды.
    /// Тип нарочно нестрогий: те же три значения носит роль ROLE_PING в
    /// Qt-версии и поле пинга в остальных клиентах.
    /// </summary>
    public object? Ping
    {
        get => _ping;
        set
        {
            if (Equals(_ping, value))
            {
                return;
            }

            _ping = value;
            Raise();
            Raise(nameof(PingText));
            Raise(nameof(PingBrush));
        }
    }

    /// <summary>
    /// Последняя строка списка. У неё линии снизу нет: под ней и так край
    /// списка. Признак ставит тот, кто собирает список: элемент внутри
    /// ItemsControl своего номера не знает.
    /// </summary>
    public bool IsLast
    {
        get => _isLast;
        set
        {
            if (value == _isLast)
            {
                return;
            }

            _isLast = value;
            Raise();
        }
    }

    /// <summary>У заголовка раздела колонки пинга нет вовсе.</summary>
    public string PingText => IsSection ? string.Empty : PingLabel(_ping).Text;

    public Brush PingBrush => PingLabel(_ping).Brush;

    public static ServerRow Section(string title)
    {
        return new ServerRow(null, true, title, string.Empty);
    }

    public static ServerRow For(Core.Server server, string subtitle)
    {
        return new ServerRow(server, false, server.Title, subtitle);
    }

    /// <summary>
    /// Текст и цвет для значения пинга.
    ///
    /// В чёрно-белой теме «хорошо/плохо» показывается яркостью: чем медленнее,
    /// тем тусклее. Отсутствие ответа подписано словами — одной яркости для
    /// такого важного случая мало. До замера стоит прочерк, а не пустота:
    /// пустое место справа выглядит так, будто строку не дорисовали.
    /// </summary>
    public static (string Text, Brush Brush) PingLabel(object? ping)
    {
        if (ping is null)
        {
            return ("—", Palette.MutedBrush);
        }

        // Единственное осмысленное булево значение — false: «не ответил».
        if (ping is bool)
        {
            return ("нет ответа", Palette.MutedBrush);
        }

        if (ping is not int ms)
        {
            return ("—", Palette.MutedBrush);
        }

        // Число в текст — через инвариантную культуру, по общему правилу порта:
        // подпись не должна зависеть от языка системы, а колонка узкая и
        // посчитана ровно под самое длинное значение.
        string text = ms.ToString(CultureInfo.InvariantCulture) + " мс";
        if (ms < 200)
        {
            return (text, Palette.TextBrush);
        }

        if (ms < 500)
        {
            return (text, Palette.DimBrush);
        }

        return (text, Palette.MutedBrush);
    }

    private void Raise([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
