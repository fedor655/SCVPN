using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Media3D;
using System.Windows.Threading;
using SCVPN.Controls;
using SCVPN.Core;
using SCVPN.Native;
using SCVPN.Theme;

namespace SCVPN.Views;

/// <summary>
/// Главное окно SCVPN. Порт ui/main_window.py.
///
/// Экран сведён к трём вещам: кнопка подключения, статус, список серверов.
/// Всё, что нажимают редко (маршрутизация, TUN, отпечаток, скачивание ядра,
/// лог), убрано в меню «⋯» — настройки никуда не делись, просто не занимают
/// место. Логика подключения по-прежнему целиком в ConnectAsync()/Disconnect();
/// ничего в фоне без твоего действия не происходит.
///
/// Фоновых потоков с сигналами здесь больше нет: ui/workers.py в порт не
/// переехал, его работу делает async/await с IProgress&lt;string&gt; вместо
/// сигнала log. А вот события ядер (XrayRunner, Tun) по-прежнему приходят из
/// чужих потоков — их раскладывает по диспетчеру <see cref="Marshal"/>.
/// </summary>
public partial class MainWindow : Window
{
    // ------------------------------------------------------------------
    // Разметочные величины для XAML. Thickness из отдельных чисел в разметке
    // не собрать, а вписывать числа руками нельзя — они живут в Theme.Metrics.
    // Поэтому статические поля, на них ссылается {x:Static} в MainWindow.xaml.

    // Шрифт сюда не дублируем: готовый FontFamily лежит в Metrics.UiFontFamily,
    // на него и ссылается разметка — как во всех окнах поверх главного.

    public static readonly Thickness HeaderMargin = new(
        Metrics.ListPadding, Metrics.HeaderTop, Metrics.HeaderTrailing, Metrics.HeaderBottom);

    public static readonly Thickness WordmarkMargin = new(Metrics.HeaderBadgeGap, 0, 0, 0);

    public static readonly Thickness PowerBlockMargin = new(
        0, Metrics.PowerBlockPadding, 0, Metrics.PowerBlockPadding);

    public static readonly Thickness StatusMargin = new(0, Metrics.StatusTop, 0, 0);

    public static readonly Thickness SubstatusMargin = new(
        Metrics.SubstatusPadding, Metrics.SubstatusTop, Metrics.SubstatusPadding, 0);

    public static readonly Thickness ModeMargin = new(0, Metrics.SubstatusLineGap, 0, 0);

    public static readonly Thickness SectionMargin = new(
        Metrics.SectionPadding, 0, Metrics.SectionPadding, Metrics.SectionBottom);

    /// <summary>
    /// Просвет под списком до лога. Поля слева и справа сюда не входят: они
    /// живут внутри строки, чтобы подсветка под курсором шла от края до края.
    /// </summary>
    public static readonly Thickness ListBottomPadding = new(0, 0, 0, Metrics.ListBottom);

    public static readonly Thickness EmptyMargin = new(Metrics.EmptyPadding);

    public static readonly Thickness EmptyHintMargin = new(0, Metrics.EmptyGap, 0, 0);

    /// <summary>
    /// Сторона знака в шапке. Числа нет в Metrics намеренно: оно нужно ровно
    /// здесь и в шкалу всего клиента не входит (в Qt-версии оно так же стояло
    /// прямо в вызове mark_pixmap).
    /// </summary>
    private const double BadgeSide = 20;

    // ------------------------------------------------------------------

    /// <summary>
    /// Яркостью состояния не различаются: «Отключено» и «Подключено» одинаково
    /// белые, а отличает их форма кольца и само слово. Список цветов на
    /// состояния был и ушёл — в чёрно-белой теме он давал только ложное чувство
    /// разницы.
    /// </summary>
    private static readonly Dictionary<string, string> StateTexts = new()
    {
        ["idle"] = "Отключено",
        ["connecting"] = "Подключение…",
        ["connected"] = "Подключено",
        ["error"] = "Не подключилось",
        // Отдельное состояние, а не "error": ошибка подключения и «отключиться
        // не вышло» — разные новости, и вторая опаснее. См. ReportTunStuck().
        ["tun_stuck"] = "Туннель не снят",
    };

    private const string TunStuckText =
        "sing-box пережил остановку: TUN-адаптер поднят, весь трафик по-прежнему\n" +
        "идёт через него, а туннель уже никем не обслуживается.\n\n" +
        "Перезагрузка компьютера снимет адаптер наверняка.";

    /// <summary>Ключ настройки, которого нет в типизированных полях Settings.</summary>
    /// <remarks>
    /// Видимость лога — вопрос интерфейса, а не логики, и в Core.Settings ему
    /// места нет. Живёт он в том же settings.json, среди неизвестных ядру
    /// ключей, которые Store сохраняет дословно.
    /// </remarks>
    private const string ShowLogKey = "show_log";

    /// <summary>User-Agent для запроса подписки; правится только руками в файле.</summary>
    private const string UserAgentKey = "user_agent";

    private readonly Profiles _profiles;
    private readonly Settings _settings;

    private readonly XrayRunner _runner = new();
    private readonly Tun _tun = new();

    /// <summary>Строки списка. Порядок тот же, что у <see cref="_rowServers"/>.</summary>
    private readonly ObservableCollection<ServerRow> _rows = new();

    /// <summary>Серверы в порядке списка — по ним идёт замер пинга.</summary>
    private List<Server> _rowServers = new();

    /// <summary>
    /// Лог фоновых задач. Progress создан на потоке интерфейса и сам туда
    /// возвращает вызовы — это и есть замена сигнала log из ui/workers.py.
    /// </summary>
    private readonly IProgress<string> _logProgress;

    /// <summary>Тикает раз в секунду, пока подключены, — считает время сессии.</summary>
    private readonly DispatcherTimer _clock;

    private ContextMenu _menu = new();
    private MenuItem? _sysproxyItem;

    private bool _wantConnected;
    private string _state = "idle";

    /// <summary>Сколько держится текущее подключение. null — не подключены.</summary>
    private Stopwatch? _connectedSince;

    /// <summary>
    /// Имя сервера, с которым ядро действительно подняли. Не тот, что выбран в
    /// списке: выбор меняется одним щелчком и живой туннель не трогает, а
    /// список показывает выбор маркером и яркостью — назвать здесь выбранный
    /// значило бы соврать заметнее прежнего.
    /// </summary>
    private string _connectedTitle = "";

    private int _activeSocksPort;
    private int _activeHttpPort;

    /// <summary>Идущий замер пинга. null — не меряем.</summary>
    private CancellationTokenSource? _pingCts;

    /// <summary>Список перестраивается — выбор меняем мы, а не пользователь.</summary>
    private bool _suppressSelection;

    /// <summary>Открытое окно подписок: его надо перерисовать после обновления.</summary>
    private SubscriptionsDialog? _subscriptionsDialog;

    public MainWindow()
    {
        InitializeComponent();

        Title = "SCVPN " + AppVersion();
        Badge.Source = Brandmark.Image(BadgeSide, Palette.TextBrush);

        _profiles = Store.LoadProfiles();
        _settings = Store.LoadSettings();
        _activeSocksPort = _settings.SocksPort;
        _activeHttpPort = _settings.HttpPort;

        _logProgress = new Progress<string>(AppendLog);

        // События ядер приходят из чужих потоков — раскладываем их по диспетчеру.
        _runner.Log += text => Marshal(() => AppendLog(text));
        _runner.StateChanged += running => Marshal(() => OnCoreState(running));
        _tun.Log += text => Marshal(() => AppendLog(text));
        _tun.StateChanged += running => Marshal(() => OnTunState(running));

        _clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _clock.Tick += (_, _) => UpdateSubstatus();

        ServerList.ItemsSource = _rows;
        RebuildMenu();
        Log.Visibility = ShowLog ? Visibility.Visible : Visibility.Collapsed;

        RefreshList();
        RenderState("idle");

        // Строка про архитектуру стоит первой намеренно: по логу сразу видно,
        // что человек на ARM-машине, и почему ядро могло скачаться «не то».
        AppendLog("[*] " + Arch.Describe());

        // Если прошлый запуск завершился аварийно, TUN мог остаться поднятым и
        // сейчас забирать весь трафик в никуда — разбираем это до всего прочего.
        Tun.CleanupStray(AppendLog);

        if (!CoreDownloader.CorePresent())
        {
            AppendLog(CoreArchMismatch()
                // «Ядро не найдено» здесь было бы неправдой: файл лежит на
                // месте, он просто от другой архитектуры и не запустится.
                ? $"[!] Ядро в bin/ скачано для {CoreDownloader.BinArch()}, а системе нужно {Arch.Host}. " +
                  "Меню «⋯» → «Скачать ядро Xray»."
                : "[!] Ядро Xray-core не найдено. Меню «⋯» → «Скачать ядро Xray».");
        }
    }

    /// <summary>Версия из сборки: одна на приложение и установщик (Directory.Build.props).</summary>
    private static string AppVersion()
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        string? informational = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrEmpty(informational))
        {
            // К информационной версии .NET дописывает «+хеш коммита» — в
            // заголовке окна он лишний.
            int plus = informational.IndexOf('+');
            return plus < 0 ? informational : informational.Substring(0, plus);
        }

        return assembly.GetName().Version?.ToString(3) ?? "0.0.0";
    }

    /// <summary>Ядро на диске есть, но скачано под другую архитектуру.</summary>
    private static bool CoreArchMismatch()
    {
        return File.Exists(Paths.XrayExe) && CoreDownloader.BinArch() != Arch.Host;
    }

    /// <summary>
    /// Выполнить действие на потоке интерфейса.
    /// </summary>
    /// <remarks>
    /// Если мы уже на нём — прямо здесь, а не через очередь. Это не экономия
    /// вызова, а порядок событий: XrayRunner.Stop() сообщает StateChanged
    /// синхронно, и Disconnect() рассчитывает, что «Отключено» нарисуется ДО
    /// того, как он проверит, снялся ли туннель, — иначе отложенное «Отключено»
    /// затёрло бы «Туннель не снят».
    ///
    /// Из чужого потока — BeginInvoke, а не Invoke: тот блокировал бы поток
    /// ядра до освобождения интерфейса, а интерфейс в этот момент вполне может
    /// сидеть в WaitForExit того же самого процесса.
    /// </remarks>
    private void Marshal(Action action)
    {
        if (Dispatcher.CheckAccess())
        {
            action();
        }
        else
        {
            Dispatcher.BeginInvoke(action);
        }
    }

    /// <summary>
    /// Запустить задачу из обработчика и не потерять её ошибку.
    /// </summary>
    /// <remarks>
    /// «_ = ЧтоТоAsync()» глотает исключение молча: до
    /// DispatcherUnhandledException в App.xaml.cs оно не доходит — упало не в
    /// обработчике события, а в брошенной задаче, и её никто не наблюдает. В
    /// Python-версии то же самое падало в обработчик Qt и было видно.
    ///
    /// Дороже всего это в подключении: если бросит что-то между
    /// RenderState("connecting") и запуском ядра, окно останется в
    /// «Подключение…», а из этого состояния OnConnectClickedAsync выходит
    /// первой же строкой — кнопка питания мертва до перезапуска приложения.
    /// Поэтому здесь же откатываем состояние.
    /// </remarks>
    private async void Fire(Task task)
    {
        try
        {
            await task;
        }
        catch (Exception e)
        {
            AppendLog($"[!] Внутренняя ошибка: {FirstLine(e.Message)}");
            if (_state == "connecting")
            {
                _wantConnected = false;
                RenderState("error");
            }
        }
    }

    // ------------------------------------------------------------------
    // Настройки
    // ------------------------------------------------------------------

    private void SaveSettings()
    {
        Store.SaveSettings(_settings);
    }

    private bool ShowLog =>
        _settings.Unknown.TryGetValue(ShowLogKey, out JsonElement value)
        && value.ValueKind == JsonValueKind.True;

    private string UserAgent =>
        _settings.Unknown.TryGetValue(UserAgentKey, out JsonElement value)
        && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";

    /// <summary>
    /// Настройка решает, видна ли полоса лога вообще; развёрнут ли лог — нет:
    /// это состояние взгляда, а не приложения, и переживать перезапуск ему
    /// незачем.
    /// </summary>
    private void ToggleLog(bool visible)
    {
        _settings.Unknown[ShowLogKey] = JsonSerializer.SerializeToElement(visible);
        SaveSettings();
        Log.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
    }

    // ------------------------------------------------------------------
    // Меню «⋯»
    // ------------------------------------------------------------------

    /// <summary>
    /// Собрать меню заново.
    /// </summary>
    /// <remarks>
    /// Пересобираем после скачивания и удаления компонентов TUN: пункт
    /// «Удалить компоненты TUN…» показывается, только когда есть что удалять, а
    /// в Qt-версии меню строилось один раз при запуске — и до перезапуска
    /// приложения пункт врал.
    /// </remarks>
    private void RebuildMenu()
    {
        var menu = new ContextMenu();

        // Маршрутизация и раздельное туннелирование — один и тот же вопрос «что
        // идёт в туннель». В Qt-версии оба выбора жили в окне «Раздельное
        // туннелирование»; здесь окно отвечает только за приложения, а выбор
        // между «всё через VPN» и «российские сайты напрямую» остался тут:
        // он работает в обоих способах подключения, а разбор по приложениям —
        // только в TUN.
        menu.Items.Add(RadioSubmenu(
            "Способ подключения",
            new[] { ("Системный прокси", "proxy"), ("TUN — весь трафик (нужен админ)", "tun") },
            () => _settings.VpnMode,
            value => { _settings.VpnMode = value; SaveSettings(); },
            OnModeChanged));

        menu.Items.Add(RadioSubmenu(
            "Маршрутизация",
            new[]
            {
                ("Авто — российские сайты напрямую", RouteMode.BypassRu),
                ("Всё через VPN", RouteMode.Global),
            },
            () => _settings.RouteMode,
            value =>
            {
                _settings.RouteMode = value;
                SaveSettings();
                if (_runner.Running)
                {
                    AppendLog("[i] Изменения применятся при следующем подключении.");
                }
            },
            null));

        var fingerprints = new List<(string, string)> { ("Авто — подобрать", "auto") };
        foreach (string name in new[] { "chrome", "firefox", "safari", "edge", "ios", "randomized" })
        {
            fingerprints.Add((name, name));
        }

        menu.Items.Add(RadioSubmenu(
            "Отпечаток TLS",
            fingerprints.ToArray(),
            () => _settings.TlsFingerprint,
            value => { _settings.TlsFingerprint = value; SaveSettings(); },
            null));

        menu.Items.Add(new Separator());

        _sysproxyItem = CheckItem(
            "Включать системный прокси",
            () => _settings.SystemProxy,
            value => { _settings.SystemProxy = value; SaveSettings(); });
        // Системный прокси имеет смысл только в режиме proxy.
        _sysproxyItem.IsEnabled = _settings.VpnMode == "proxy";
        menu.Items.Add(_sysproxyItem);

        menu.Items.Add(CheckItem(
            "Блокировать рекламу",
            () => _settings.BlockAds,
            value => { _settings.BlockAds = value; SaveSettings(); }));

        menu.Items.Add(new Separator());
        menu.Items.Add(MenuAction("Раздельное туннелирование…", EditSplitTunnel));
        menu.Items.Add(MenuAction("Подписки…", ManageSubscriptions));
        menu.Items.Add(MenuAction("Измерить пинг", () => Fire(PingAllAsync())));
        menu.Items.Add(MenuAction("Скачать ядро Xray", () => Fire(DownloadCoreAsync())));
        menu.Items.Add(MenuAction("Скачать компоненты TUN", () => Fire(DownloadTunAsync())));

        // Показываем, только когда есть что удалять: пункт «удалить» над пустым
        // местом — обещание действия, которое ничего не сделает.
        if (CoreDownloader.TunPresent())
        {
            menu.Items.Add(MenuAction("Удалить компоненты TUN…", RemoveTun));
        }

        menu.Items.Add(new Separator());
        menu.Items.Add(CheckItem("Показывать лог ядра", () => ShowLog, ToggleLog));

        _menu = menu;
    }

    private static MenuItem MenuAction(string label, Action handler)
    {
        var item = new MenuItem { Header = label };
        item.Click += (_, _) => handler();
        return item;
    }

    private static MenuItem CheckItem(string label, Func<bool> get, Action<bool> set)
    {
        var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = get() };
        // Щелчок по отмечаемому пункту переключает галочку сам, до Click, —
        // значит здесь уже новое значение.
        item.Click += (_, _) => set(item.IsChecked);
        return item;
    }

    /// <summary>
    /// Взаимоисключающие пункты меню, привязанные к настройке.
    /// </summary>
    /// <remarks>
    /// Взаимное исключение расставляем руками: GroupName есть у RadioButton, но
    /// не у MenuItem, а QActionGroup из Qt в WPF соответствия не имеет. Заодно
    /// это чинит повторный щелчок по уже выбранному пункту: сам по себе он снял
    /// бы галочку и меню осталось бы без единого выбранного варианта.
    /// </remarks>
    private static MenuItem RadioSubmenu(
        string title,
        (string Label, string Value)[] options,
        Func<string> get,
        Action<string> set,
        Action? onChange)
    {
        var parent = new MenuItem { Header = title };
        string current = get();
        var items = new List<MenuItem>();

        foreach ((string label, string value) in options)
        {
            var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = current == value };
            // Отметка кружком, а не галочкой: пункты взаимоисключающие. Метку
            // для шаблона ставит стиль RadioMenuItem из Theme.xaml — без него
            // отличить «один из» от «включено» было бы нечем. Ссылка отложенная:
            // пункт в этот момент ещё не в дереве, а искать ресурс через
            // Application.Current значило бы уронить окно там, где приложения нет.
            item.SetResourceReference(StyleProperty, "RadioMenuItem");
            string picked = value;
            item.Click += (_, _) =>
            {
                foreach (MenuItem other in items)
                {
                    other.IsChecked = ReferenceEquals(other, item);
                }

                set(picked);
                onChange?.Invoke();
            };
            items.Add(item);
            parent.Items.Add(item);
        }

        return parent;
    }

    private void OnMenuClick(object sender, RoutedEventArgs e)
    {
        _menu.PlacementTarget = MenuButton;
        _menu.Placement = PlacementMode.Bottom;
        _menu.IsOpen = true;
    }

    private void OnModeChanged()
    {
        string mode = _settings.VpnMode;
        if (_sysproxyItem != null)
        {
            _sysproxyItem.IsEnabled = mode == "proxy";
        }

        if (mode == "tun" && !Elevation.Privileged())
        {
            AppendLog("[i] TUN потребует прав администратора при подключении.");
        }

        UpdateSubstatus();
    }

    // ------------------------------------------------------------------
    // Список серверов
    // ------------------------------------------------------------------

    /// <param name="keepPings">
    /// Пинги переживают обычное перечитывание списка: сервер тот же, мерить
    /// незачем. А вот после обновления подписки их надо сбросить: за тем же
    /// именем может стоять уже другой сервер, и старое число врало бы.
    /// </param>
    private void RefreshList(bool keepPings = true)
    {
        var previousPings = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (keepPings)
        {
            foreach (ServerRow row in _rows)
            {
                if (row.Server != null)
                {
                    previousPings[row.Server.Key()] = row.Ping;
                }
            }
        }

        List<Server> servers = _profiles.AllServers();
        _rowServers = servers;
        string selectedKey = _settings.SelectedKey;

        _suppressSelection = true;
        try
        {
            _rows.Clear();
            ServerRow? selected = null;
            foreach (Server s in servers)
            {
                var row = ServerRow.For(s, ProtoLabel(s));
                if (previousPings.TryGetValue(s.Key(), out object? ping))
                {
                    row.Ping = ping;
                }

                _rows.Add(row);
                if (s.Key() == selectedKey)
                {
                    selected = row;
                }
            }

            // У последней строки линии снизу нет: под ней и так край списка.
            if (_rows.Count > 0)
            {
                _rows[_rows.Count - 1].IsLast = true;
            }

            ServerList.SelectedItem = selected ?? (_rows.Count > 0 ? _rows[0] : null);
        }
        finally
        {
            _suppressSelection = false;
        }

        // Выбор мог смениться сам (первый сервер вместо исчезнувшего) — тогда
        // настройка обязана догнать список, иначе подключимся не туда.
        Server? current = CurrentServer();
        if (current != null && current.Key() != selectedKey)
        {
            _settings.SelectedKey = current.Key();
            SaveSettings();
        }

        bool empty = servers.Count == 0;
        EmptyView.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ServerList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        UpdateSubstatus();
    }

    /// <summary>
    /// Что видно под именем: протокол, адрес и транспорт — то, по чему
    /// пользователь отличает два сервера с одинаковым названием.
    /// </summary>
    private static string ProtoLabel(Server s)
    {
        var parts = new List<string>
        {
            s.Protocol,
            s.Address + ":" + s.Port.ToString(CultureInfo.InvariantCulture),
        };
        if (s.Security != "" && s.Security != "none")
        {
            parts.Add(s.Security);
        }

        if (s.Network != "tcp")
        {
            parts.Add(s.Network);
        }

        return string.Join(" · ", parts);
    }

    private Server? CurrentServer()
    {
        return (ServerList.SelectedItem as ServerRow)?.Server;
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection)
        {
            return;
        }

        Server? s = CurrentServer();
        if (s == null)
        {
            return;
        }

        string was = _settings.SelectedKey;
        _settings.SelectedKey = s.Key();
        SaveSettings();
        UpdateSubstatus();

        // Ядро уже запущено с прежним конфигом и само не переедет: без этой
        // строки список показывал бы один сервер, а трафик шёл через другой.
        // Android говорит то же самое.
        if (was != s.Key() && _state == "connected")
        {
            AppendLog("[i] Сервер сменится при следующем подключении");
        }
    }

    private void OnListDoubleClick(object sender, MouseButtonEventArgs e)
    {
        // Двойной щелчок по пустому месту списка подключать не должен.
        if (ContainerFrom(e.OriginalSource as DependencyObject) == null)
        {
            return;
        }

        Fire(OnConnectClickedAsync());
    }

    private void OnListRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        ListBoxItem? container = ContainerFrom(e.OriginalSource as DependencyObject);
        if (container == null)
        {
            return;
        }

        container.IsSelected = true;

        var menu = new ContextMenu();
        menu.Items.Add(MenuAction("Подключиться", () => Fire(OnConnectClickedAsync())));
        menu.Items.Add(MenuAction("Удалить", RemoveSelected));
        menu.PlacementTarget = container;
        menu.Placement = PlacementMode.MousePoint;
        menu.IsOpen = true;
        e.Handled = true;
    }

    /// <summary>Строка списка, в которую попали мышью, либо null.</summary>
    private static ListBoxItem? ContainerFrom(DependencyObject? source)
    {
        while (source != null && source is not ListBoxItem)
        {
            // Источником события бывает и не-Visual (Run внутри текста), а
            // VisualTreeHelper такие не принимает — для них логическое дерево.
            source = source is Visual or Visual3D
                ? VisualTreeHelper.GetParent(source)
                : LogicalTreeHelper.GetParent(source);
        }

        return source as ListBoxItem;
    }

    private void OnWindowKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Delete && ServerList.IsKeyboardFocusWithin)
        {
            RemoveSelected();
            e.Handled = true;
        }
    }

    private void RemoveSelected()
    {
        Server? s = CurrentServer();
        if (s == null)
        {
            return;
        }

        // Удаляем из одиночных и из подписок по ключу.
        string key = s.Key();
        _profiles.Servers = _profiles.Servers.Where(x => x.Key() != key).ToList();
        foreach (Subscription sub in _profiles.Subscriptions)
        {
            sub.Servers = sub.Servers.Where(x => x.Key() != key).ToList();
        }

        Store.SaveProfiles(_profiles);
        RefreshList();
        AppendLog($"[-] Удалён: {s.Title}");
    }

    // ------------------------------------------------------------------
    // Подключение / отключение
    // ------------------------------------------------------------------

    private void OnPowerClick(object sender, RoutedEventArgs e)
    {
        Fire(OnConnectClickedAsync());
    }

    private async Task OnConnectClickedAsync()
    {
        if (_state == "connecting")
        {
            return;   // подбор отпечатка уже идёт — не мешаем
        }

        if (_runner.Running)
        {
            Disconnect();
        }
        else
        {
            await ConnectAsync();
        }
    }

    private async Task ConnectAsync()
    {
        Server? server = CurrentServer();
        if (server == null)
        {
            MessageDialog.Warning(this, "Сначала добавь и выбери сервер из списка.", "Нет сервера");
            return;
        }

        if (!CoreDownloader.CorePresent())
        {
            MessageDialog.Warning(this, "Меню «⋯» → «Скачать ядро Xray».", "Нет ядра");
            return;
        }

        string mode = _settings.VpnMode;
        if (mode == "tun" && !TunPreflight())
        {
            return;
        }

        _wantConnected = true;
        RenderState("connecting");
        AppendLog($"[*] Подключаюсь к: {server.Title}");

        string over = _settings.TlsFingerprint;
        bool needsFp = server.Security is "reality" or "tls";

        if (!needsFp || over != "auto")
        {
            // Конкретный отпечаток или транспорт без TLS — стартуем сразу.
            StartWithFingerprint(server, over != "auto" ? over : "");
            return;
        }

        // Авто: в фоне подбираем рабочий отпечаток, потом стартуем.
        string routeMode = _settings.RouteMode;
        bool blockAds = _settings.BlockAds;

        string fingerprint;
        try
        {
            fingerprint = await FingerprintProbe.FindWorkingAsync(
                server, "auto", routeMode, blockAds, _logProgress.Report);
        }
        catch (Exception e)
        {
            _wantConnected = false;
            RenderState("error");
            AppendLog($"[!] Ошибка подбора отпечатка: {FirstLine(e.Message)}");
            return;
        }

        // Пока подбирали, могли нажать «отключиться» — тогда стартовать нечего.
        if (_wantConnected)
        {
            StartWithFingerprint(server, fingerprint);
        }
    }

    // ------------------------------------------------------------------
    // Префлайт TUN: компоненты и права
    // ------------------------------------------------------------------

    /// <summary>
    /// Всё ли готово для TUN. false — идти дальше нельзя, пользователю сказано.
    /// </summary>
    /// <remarks>
    /// Порядок шагов не вкусовщина. Компоненты TUN — два файла рядом с
    /// приложением (sing-box и wintun.dll), которые кладёт установщик, а
    /// права — независимый от них UAC. Проверять файлы первыми правильно:
    /// иначе пользователь крутил бы круг UAC только затем, чтобы следом
    /// прочитать «нет компонентов».
    /// </remarks>
    private bool TunPreflight()
    {
        return EnsureTunComponents() && EnsurePrivilege();
    }

    private bool EnsureTunComponents()
    {
        if (CoreDownloader.TunPresent())
        {
            return true;
        }

        MessageDialog.Warning(this, "Меню «⋯» → «Скачать компоненты TUN».", "Нет компонентов TUN");
        return false;
    }

    /// <summary>Права на TUN: есть — true; получили — true; иначе false.</summary>
    private bool EnsurePrivilege()
    {
        if (Elevation.Privileged())
        {
            return true;
        }

        if (!MessageDialog.Question(this, Elevation.PrivilegeQuestion, "Нужны права администратора"))
        {
            return false;
        }

        string outcome = Elevation.AcquirePrivilege();
        if (outcome == "restart")
        {
            // Права на Windows добываются только перезапуском: новый процесс уже
            // просит UAC, а этот обязан уйти.
            Application.Current.Shutdown();
            return false;
        }

        // Elevation.LastError — настоящая причина отказа («нажато «Нет» в
        // диалоге UAC», запрет политикой). Зашитая фраза ни о чём — ровно то,
        // из-за чего первое включение TUN било пользователя мимо цели.
        string detail = Elevation.LastError;
        AppendLog(detail.Length > 0
            ? $"[!] Не удалось поставить системный компонент: {detail}"
            : "[!] Не удалось поставить системный компонент.");
        MessageDialog.Warning(
            this,
            detail.Length > 0 ? detail : "Не удалось получить права администратора.",
            "Не вышло");
        return false;
    }

    /// <summary>Собрать конфиг с выбранным отпечатком и запустить ядро.</summary>
    private void StartWithFingerprint(Server server, string fingerprint)
    {
        Server srv = server.Clone();
        if (fingerprint.Length > 0)
        {
            srv.Fingerprint = fingerprint;
        }

        string mode = _settings.VpnMode;
        string routeMode = _settings.RouteMode;

        // Свободные порты, чтобы не конфликтовать с другими клиентами (Happ и т.п.).
        int socksPort = FreePort.Find(_settings.SocksPort);
        int httpPort = FreePort.Find(Math.Max(_settings.HttpPort, socksPort + 1));
        _activeSocksPort = socksPort;
        _activeHttpPort = httpPort;
        _connectedTitle = srv.Title;

        System.Text.Json.Nodes.JsonObject cfg = XrayConfigBuilder.Build(
            srv,
            socksPort: socksPort,
            httpPort: httpPort,
            routeMode: routeMode,
            blockAds: _settings.BlockAds,
            logLevel: "warning");

        AppendLog($"[*] Порты SOCKS={socksPort}, HTTP={httpPort}, отпечаток={srv.Fingerprint}");
        try
        {
            _runner.Start(cfg);
        }
        catch (Exception e)
        {
            _wantConnected = false;
            RenderState("error");
            MessageDialog.Error(this, e.Message, "Ошибка запуска ядра");
            return;
        }

        if (mode == "tun")
        {
            try
            {
                _tun.Start(srv, _activeSocksPort, _settings.SplitMode, _settings.SplitApps);
            }
            catch (Exception e)
            {
                AppendLog($"[!] Не удалось включить TUN: {e.Message}");
                MessageDialog.Error(this, e.Message, "Ошибка TUN");
                Disconnect();
            }
        }
        else if (_settings.SystemProxy)
        {
            try
            {
                SystemProxy.Enable("127.0.0.1", _activeHttpPort);
                AppendLog($"[*] Системный прокси включён (127.0.0.1:{_activeHttpPort})");
            }
            catch (Exception e)
            {
                AppendLog($"[!] Не удалось включить системный прокси: {e.Message}");
            }
        }
    }

    private void Disconnect()
    {
        _wantConnected = false;
        // Сначала TUN — он вернёт маршруты в исходное состояние.
        bool tunDown = _tun.Stop();
        if (SystemProxy.IsEnabled)
        {
            SystemProxy.Disable();
            AppendLog("[*] Системный прокси выключён");
        }

        _runner.Stop();
        // После _runner.Stop(): она синхронно приводит к OnCoreState(false), а
        // та рисует "idle" — то самое «Отключено», которое здесь было бы ложью.
        if (!tunDown)
        {
            ReportTunStuck();
        }
    }

    /// <summary>
    /// Туннель не снялся, и об этом сказал не наш домысел, а сам sing-box.
    /// </summary>
    /// <remarks>
    /// Tun.Stop() возвращает false только по правдивому ответу: процесс пережил
    /// и остановку, и добивание, адаптер поднят, маршруты держатся. Показать
    /// «Отключено» в этот момент — соврать ровно там, где правду специально
    /// добывали.
    /// </remarks>
    private void ReportTunStuck()
    {
        AppendLog("[!] ТРЕВОГА: туннель не снят — sing-box пережил остановку.");
        RenderState("tun_stuck");
        MessageDialog.Warning(this, TunStuckText, "Туннель не снят");
    }

    private void OnCoreState(bool running)
    {
        if (running)
        {
            _connectedSince = Stopwatch.StartNew();
            _clock.Start();
            RenderState("connected");
            return;
        }

        _connectedSince = null;
        _connectedTitle = "";
        _clock.Stop();

        // Если ядро упало само, а мы думали что подключены — приберём всё.
        if (_wantConnected)
        {
            _wantConnected = false;
            bool tunDown = _tun.Stop();
            if (SystemProxy.IsEnabled)
            {
                SystemProxy.Disable();
            }

            AppendLog("[!] Соединение разорвано (ядро остановилось).");
            RenderState("error");
            if (!tunDown)
            {
                ReportTunStuck();
            }
        }
        else
        {
            RenderState("idle");
        }
    }

    private void OnTunState(bool running)
    {
        if (running)
        {
            AppendLog("[tun] TUN-адаптер активен — весь трафик идёт через VPN.");
            return;
        }

        if (!_wantConnected || _settings.VpnMode != "tun")
        {
            return;
        }

        // TUN упал во время сессии — рвём всё, чтобы не остаться без сети.
        //
        // _wantConnected = false ОБЯЗАН стоять раньше _tun.Stop() и
        // _runner.Stop() — не только по смыслу, а из-за реального переплетения
        // событий. _runner.Stop() синхронно (тот же поток) дёргает
        // OnCoreState(false) прямо изнутри этого же вызова — а у OnCoreState
        // своя ветка `if (_wantConnected) { ... _tun.Stop() ... }`, дословно
        // повторяющая эту уборку. Если _wantConnected к этому моменту всё ещё
        // true, OnCoreState отработает её ЕЩЁ РАЗ поверх текущей — повторные
        // Tun.Stop()/SystemProxy.Disable(), конфликтующий лог и RenderState
        // ("error") поверх состояния, которое ещё не доделали здесь. Сбросив
        // флаг первой строкой, вторая ветка видит его уже false и просто
        // откатывается в "idle", не начиная свою уборку заново.
        AppendLog("[!] TUN остановился — отключаюсь.");
        _wantConnected = false;
        // Закрыть соединение с sing-box (Tun уже знает, что не жив).
        bool tunDown = _tun.Stop();
        _runner.Stop();
        if (SystemProxy.IsEnabled)
        {
            SystemProxy.Disable();
        }

        if (!tunDown)
        {
            ReportTunStuck();
        }
    }

    // ------------------------------------------------------------------
    // Статус
    // ------------------------------------------------------------------

    private void RenderState(string state)
    {
        _state = state;
        Power.State = state;
        StatusLabel.Text = StateTexts[state];
        UpdateSubstatus();
    }

    private void UpdateSubstatus()
    {
        SubstatusLabel.Text = DetailLine();
        ModeLabel.Text = ModeCaption();
    }

    /// <summary>
    /// Что происходит прямо сейчас: при живом подключении — какой сервер держит
    /// трафик и сколько уже держит, в остальных случаях — куда собирались
    /// подключаться.
    /// </summary>
    private string DetailLine()
    {
        if (_state == "connected" && _connectedSince != null)
        {
            long secs = (long)_connectedSince.Elapsed.TotalSeconds;
            // Инвариантная культура не ради разделителя, а ради цифр: в
            // арабской локали строка ушла бы в восточные цифры.
            string uptime = secs >= 3600
                ? string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}",
                    secs / 3600, secs / 60 % 60, secs % 60)
                : string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}",
                    secs / 60, secs % 60);
            // Разделитель тот же, что на macOS и Android: строка обязана
            // читаться одинаково на всех платформах.
            return _connectedTitle.Length == 0 ? uptime : $"{_connectedTitle}  ·  {uptime}";
        }

        if (_state == "tun_stuck")
        {
            return "Трафик всё ещё идёт через туннель";
        }

        Server? server = CurrentServer();
        return server?.Title ?? "";
    }

    /// <summary>
    /// Режим — только при живом подключении.
    /// </summary>
    /// <remarks>
    /// В простое он ни о чём не сообщает: ничего ещё не выбрано и никуда не
    /// идёт. Пустая строка при этом остаётся в раскладке, иначе список под ней
    /// прыгал бы на каждом подключении.
    /// </remarks>
    private string ModeCaption()
    {
        if (_state != "connected")
        {
            return "";
        }

        return _settings.VpnMode == "tun" ? "ВЕСЬ ТРАФИК" : "СИСТЕМНЫЙ ПРОКСИ";
    }

    // ------------------------------------------------------------------
    // Управление серверами
    // ------------------------------------------------------------------

    private void OnAddClick(object sender, RoutedEventArgs e)
    {
        Fire(AddSomethingAsync());
    }

    /// <summary>Одно поле на оба случая: ссылка распознаётся сама, иначе это подписка.</summary>
    private async Task AddSomethingAsync()
    {
        var dlg = new AddDialog { Owner = this };
        if (dlg.ShowDialog() != true)
        {
            return;
        }

        string text = dlg.Result;
        if (text.Length == 0)
        {
            return;
        }

        Server? s = LinkParser.ParseLink(text);
        if (s != null)
        {
            _profiles.Servers.Add(s);
            Store.SaveProfiles(_profiles);
            RefreshList();
            AppendLog($"[+] Добавлен сервер: {s.Title}");
            return;
        }

        if (!text.StartsWith("http://", StringComparison.Ordinal)
            && !text.StartsWith("https://", StringComparison.Ordinal))
        {
            MessageDialog.Warning(
                this, "Это не похоже ни на ссылку сервера, ни на URL подписки.", "Не распознано");
            return;
        }

        string? name = MessageDialog.Prompt(this, "Имя подписки", "Название (как показывать):", "Моя подписка");
        if (name == null)
        {
            return;
        }

        var sub = new Subscription
        {
            Name = name.Trim().Length > 0 ? name.Trim() : "Подписка",
            Url = text,
            Added = Store.NowIso(),
        };
        // В профиль подписка попадает только после успешной загрузки (это
        // делает FetchSubscriptionAsync): иначе опечатка в адресе оставляла
        // мёртвую запись навсегда — она не грузится, но занимает место и
        // удаляется только руками.
        await FetchSubscriptionAsync(sub);
    }

    private void OnRefreshClick(object sender, RoutedEventArgs e)
    {
        Fire(UpdateSubscriptionsAsync());
    }

    private async Task UpdateSubscriptionsAsync()
    {
        if (_profiles.Subscriptions.Count == 0)
        {
            MessageDialog.Info(this, "Сначала добавь подписку кнопкой  +", "Нет подписок");
            return;
        }

        // Копия списка: успешная загрузка новой подписки дописывает его.
        foreach (Subscription sub in _profiles.Subscriptions.ToList())
        {
            await FetchSubscriptionAsync(sub);
        }
    }

    private void EditSplitTunnel()
    {
        var dlg = new SplitTunnelDialog(_settings.SplitMode, _settings.SplitApps) { Owner = this };
        if (dlg.ShowDialog() != true)
        {
            return;
        }

        _settings.SplitMode = dlg.Mode;
        _settings.SplitApps = dlg.Apps;
        SaveSettings();
        AppendLog($"[*] Маршрутизация: {dlg.Summary}");

        // Разбор по приложениям делает sing-box, а он поднимается только в TUN.
        bool needsTun = dlg.Mode != SplitMode.Off && dlg.Apps.Count > 0;
        if (needsTun && _settings.VpnMode != "tun")
        {
            MessageDialog.Info(
                this,
                "Разбор по приложениям работает только в режиме\n" +
                "«TUN — весь трафик». Переключи способ подключения в этом же меню.\n\n" +
                "Режимы «Авто» и «Всё через VPN» работают в обоих способах.",
                "Нужен TUN-режим");
        }
        else if (_runner.Running)
        {
            AppendLog("[i] Изменения применятся при следующем подключении.");
        }
    }

    /// <summary>
    /// Экран подписок: статистика, ссылка, QR, удаление.
    /// </summary>
    /// <remarks>
    /// Удалить сервер поштучно можно правой кнопкой по строке, а всю подписку
    /// целиком — только отсюда: иначе её серверы вернулись бы при «Обновить».
    ///
    /// Выбирать подписку заранее, как это делал QInputDialog в Qt-версии, не
    /// нужно: окно показывает сразу все карточками.
    /// </remarks>
    private void ManageSubscriptions()
    {
        var dlg = new SubscriptionsDialog(_profiles) { Owner = this };
        dlg.UpdateRequested += FetchSubscriptionAsync;
        dlg.DeleteRequested += sub =>
        {
            _profiles.Subscriptions.Remove(sub);
            Store.SaveProfiles(_profiles);
            RefreshList();
            AppendLog($"[-] Удалена подписка: {sub.Name}");
            dlg.Refresh();
        };

        _subscriptionsDialog = dlg;
        try
        {
            dlg.ShowDialog();
        }
        finally
        {
            _subscriptionsDialog = null;
        }
    }

    private async Task FetchSubscriptionAsync(Subscription sub)
    {
        string ua = UserAgent;
        AppendLog($"[*] Обновляю подписку «{sub.Name}»…");

        SubscriptionResult result;
        try
        {
            result = await SubscriptionFetcher.FetchAsync(
                sub.Url,
                Hwid.DeviceHeaders(),
                ua.Length > 0 ? ua : SubscriptionFetcher.DefaultUserAgent);
        }
        catch (Exception e)
        {
            AppendLog($"[!] Ошибка подписки «{sub.Name}»: {FirstLine(e.Message)}");
            // Показываем всегда, а не только отказ панели: раньше сетевая
            // ошибка или кривой ответ уходили в один лог, и нажатие «Обновить»
            // выглядело как «ничего не произошло». Текст SubscriptionException
            // уже написан для человека, остальное показываем как есть.
            MessageDialog.Warning(this, e.Message.Trim(), $"Подписка «{sub.Name}»");
            return;
        }

        if (result.Servers.Count == 0)
        {
            AppendLog($"[!] Подписка «{sub.Name}»: серверов не нашлось");
            MessageDialog.Warning(
                this, "Панель ответила, но серверов в ответе нет.", $"Подписка «{sub.Name}»");
            return;
        }

        sub.Servers = result.Servers;
        sub.Info = result.Info;
        sub.Updated = Store.NowIso();
        // Название от панели точнее того, что пользователь ввёл руками.
        if (result.Info.Title.Length > 0
            && (sub.Name.Length == 0 || sub.Name == "Подписка" || sub.Name == "Моя подписка"))
        {
            sub.Name = result.Info.Title;
        }

        // Новая подписка добавляется здесь, а не до похода в сеть.
        if (_profiles.Subscriptions.All(x => x.Url != sub.Url))
        {
            _profiles.Subscriptions.Add(sub);
        }

        Store.SaveProfiles(_profiles);
        RefreshList(keepPings: false);
        AppendLog($"[+] Подписка «{sub.Name}»: {result.Servers.Count} серверов, пинги сброшены");
        _subscriptionsDialog?.Refresh();
    }

    // ------------------------------------------------------------------
    // Пинг
    // ------------------------------------------------------------------

    private void OnPingClick(object sender, RoutedEventArgs e)
    {
        Fire(PingAllAsync());
    }

    /// <summary>
    /// Замер задержки до всех серверов — по очереди, а не веером: каждая проба
    /// поднимает своё ядро.
    /// </summary>
    private async Task PingAllAsync()
    {
        if (_rowServers.Count == 0)
        {
            return;
        }

        // При живом подключении замер уходит в сам туннель и меряет дорогу до
        // сервера через сервер: цифры выглядели бы настоящими, но были бы
        // выдумкой. Отказ с объяснением, а не молча.
        if (_runner.Running)
        {
            AppendLog("[!] Отключись, чтобы померить пинг: "
                      + "сейчас замер пойдёт через сам туннель.");
            return;
        }

        // Второй замер поверх идущего только сбивал бы первый: в Qt-версии на
        // это уходил ещё один поток со своими ядрами, и два ядра мерили друг
        // против друга.
        if (_pingCts != null)
        {
            return;
        }

        AppendLog("[*] Пингую серверы…");

        // Ядра нет — мерить через сервер нечем. Откатываемся на TCP: числа
        // означают меньше, но список серверов остаётся полезным, а не
        // заполняется сплошным «нет ответа».
        bool throughCore = File.Exists(Paths.XrayExe);
        if (!throughCore)
        {
            AppendLog("[!] Ядра нет — меряю пинг по TCP, "
                      + "это проверка порта, а не работоспособности сервера.");
        }

        string routeMode = _settings.RouteMode;
        var cts = new CancellationTokenSource();
        _pingCts = cts;
        try
        {
            foreach (Server s in _rowServers.ToList())
            {
                int? ms = throughCore
                    ? await FingerprintProbe.PingDelayAsync(s, routeMode, ct: cts.Token)
                    : await TcpPing.MeasureAsync(s.Address, s.Port, TcpPingTimeout, cts.Token);
                ApplyPing(s.Key(), ms);
            }

            AppendLog("[*] Пинг завершён");
        }
        catch (OperationCanceledException)
        {
            // Отменяем замер только при закрытии окна — говорить об этом уже
            // некому, но и падать посреди уборки нельзя.
        }
        finally
        {
            _pingCts = null;
            cts.Dispose();
        }
    }

    /// <summary>Таймаут TCP-замера. Три секунды — как в ping.py.</summary>
    private static readonly TimeSpan TcpPingTimeout = TimeSpan.FromSeconds(3);

    private void ApplyPing(string key, int? ms)
    {
        foreach (ServerRow row in _rows)
        {
            if (row.Server != null && row.Server.Key() == key)
            {
                // null от замера означает «не ответил» — в строке это false,
                // а null оставлен под «ещё не мерили».
                row.Ping = ms is null ? false : ms.Value;
                return;
            }
        }
    }

    // ------------------------------------------------------------------
    // Скачивание ядра
    // ------------------------------------------------------------------

    private async Task DownloadCoreAsync()
    {
        AppendLog("[*] Скачиваю ядро Xray-core…");
        await RunDownloadAsync(
            CoreDownloader.DownloadCoreAsync,
            tag => $"Ядро Xray-core {tag} установлено.",
            "ядро");
    }

    private async Task DownloadTunAsync()
    {
        // wintun — драйвер виртуального адаптера: без него sing-box не поднимет
        // интерфейс, поэтому качаются оба файла разом.
        AppendLog("[*] Скачиваю sing-box + wintun (для TUN-режима)…");
        await RunDownloadAsync(
            CoreDownloader.DownloadTunAsync,
            tag => $"TUN-компоненты установлены (sing-box {tag}).",
            "TUN");
    }

    /// <summary>
    /// Общая обвязка загрузки: окно с полоской, лог, сообщение по завершении.
    /// </summary>
    /// <remarks>
    /// Окно показывает себя само в конструкторе — второй Show() тут не нужен.
    ///
    /// Отмена, в отличие от Qt-версии, настоящая: загрузчик умеет
    /// CancellationToken, и кнопка окна дёргает именно его. Без этой связки
    /// нажатие «Отмена» гасило бы кнопку и молча не меняло ничего — ровно то
    /// враньё, из-за которого в Qt-версии кнопки не было вовсе.
    ///
    /// Полоска стартует бегущей. Кто умеет считать байты, переведёт её в
    /// проценты первым же сообщением о них; кто не умеет — оставит бегущей до
    /// конца, и это честно.
    /// </remarks>
    private async Task RunDownloadAsync(
        Func<IProgress<string>, IProgress<DownloadProgress>, CancellationToken, Task<string>> download,
        Func<string, string> successText,
        string what)
    {
        var dlg = new ProgressDialog($"Скачиваю {what}…", this);
        using var cts = new CancellationTokenSource();
        dlg.CancelRequested += cts.Cancel;

        // Строки идут и в лог, и в окно загрузки: в окне видно текущий шаг, в
        // логе — вся история, включая то, что пролистнулось.
        var log = new Progress<string>(text =>
        {
            AppendLog(text);
            dlg.SetText(text);
        });
        var bytes = new Progress<DownloadProgress>(p => dlg.Report(p.Got, p.Total));

        try
        {
            string tag = await download(log, bytes, cts.Token);
            CloseProgress(dlg);
            MessageDialog.Info(this, successText(tag), "Готово");
            // Компоненты TUN могли появиться — значит, появился и пункт «Удалить».
            RebuildMenu();
        }
        catch (OperationCanceledException)
        {
            CloseProgress(dlg);
            AppendLog($"[i] Загрузка ({what}) отменена.");
        }
        catch (Exception e)
        {
            CloseProgress(dlg);
            AppendLog($"[!] Не удалось скачать {what}: {FirstLine(e.Message)}");
        }
    }

    /// <summary>Закрыть окно загрузки, если оно ещё открыто.</summary>
    /// <remarks>
    /// Проверка обязательна: окно можно закрыть крестиком, не дожидаясь конца,
    /// а Window.Close() на уже закрытом окне бросает InvalidOperationException.
    /// Без неё успешная загрузка после такого закрытия падала бы прямо на
    /// строке закрытия — и «Готово» вместе с пересборкой меню терялись бы.
    /// </remarks>
    private static void CloseProgress(ProgressDialog dlg)
    {
        if (dlg.IsVisible)
        {
            dlg.Finish();
        }
    }

    /// <summary>
    /// Удалить sing-box и wintun.dll.
    /// </summary>
    /// <remarks>
    /// Отключаемся первыми: удалять файлы из-под работающего туннеля нельзя —
    /// занятый sing-box.exe Windows удалить не даст, и пользователь увидел бы
    /// ошибку системы вместо действия.
    /// </remarks>
    private void RemoveTun()
    {
        bool yes = MessageDialog.Question(
            this,
            "TUN-режим перестанет работать, пока компоненты не скачают заново.\n" +
            "Удалить?",
            "Удалить компоненты TUN");
        if (!yes)
        {
            return;
        }

        Disconnect();

        bool removed;
        try
        {
            removed = CoreDownloader.RemoveTun(_logProgress);
        }
        catch (Exception e)
        {
            AppendLog($"[!] Не удалось удалить компоненты TUN: {e.Message}");
            MessageDialog.Warning(this, e.Message, "Не вышло");
            return;
        }

        AppendLog(removed
            ? "[*] Компоненты TUN удалены."
            : "[i] Компоненты TUN и так не были установлены.");
        RebuildMenu();
    }

    // ------------------------------------------------------------------
    // Прочее
    // ------------------------------------------------------------------

    private void AppendLog(string text)
    {
        Log.Append(text);
    }

    /// <summary>Первая строка сообщения — в лог длинные тексты не влезают.</summary>
    private static string FirstLine(string text)
    {
        int line = text.IndexOf('\n');
        return (line < 0 ? text : text.Substring(0, line)).TrimEnd('\r');
    }

    // ------------------------------------------------------------------
    // Закрытие окна — обязательно вернуть систему в исходное состояние
    // ------------------------------------------------------------------

    protected override void OnClosing(CancelEventArgs e)
    {
        try
        {
            _pingCts?.Cancel();
            // Таймер живёт на диспетчере, а не на окне: сам он от закрытия окна
            // не остановится и продолжит дёргать UpdateSubstatus() по мёртвой
            // разметке, пока приложение не завершится окончательно.
            _clock.Stop();

            bool tunDown = _tun.Stop();   // вернуть маршруты и адаптер
            if (SystemProxy.IsEnabled)
            {
                SystemProxy.Disable();
            }

            _runner.Stop();
            // Именно на закрытии молчать нельзя больше всего: приложения через
            // секунду не будет, а поднятый адаптер с мёртвым туннелем
            // останется — без этого сообщения пользователь узнает о нём по
            // пропавшей сети.
            if (!tunDown)
            {
                ReportTunStuck();
            }
        }
        finally
        {
            base.OnClosing(e);
        }
    }
}
