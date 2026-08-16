using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Threading;
using SCVPN.Core;

namespace SCVPN.Native;

/// <summary>
/// TUN-режим для Windows: весь трафик устройства идёт через VPN.
/// </summary>
/// <remarks>
/// Как устроено (намеренно просто и прозрачно):
/// <list type="bullet">
/// <item>Xray уже работает и слушает локальный SOCKS (как в режиме прокси) —
/// именно он делает TLS/Reality-рукопожатие с сервером. Этот путь одинаков в
/// обоих режимах, поэтому автоподбор отпечатка остаётся в силе.</item>
/// <item>sing-box поднимает виртуальный TUN-адаптер (через wintun.dll),
/// забирает ВЕСЬ трафик системы и заворачивает его в этот локальный SOCKS
/// Xray.</item>
/// <item>Чтобы не было петли (соединение самого Xray к серверу не должно снова
/// попасть в TUN), IP сервера добавляется в route_exclude_address — sing-box
/// сам прописывает обходной маршрут и САМ ЖЕ убирает все маршруты при
/// выходе.</item>
/// </list>
/// TUN требует прав администратора (создание адаптера и правка таблицы
/// маршрутов). Сам запрос прав живёт в <see cref="Elevation"/>, здесь только
/// проверка: поднимать туннель без прав бессмысленно.
///
/// Сборка конфига — в <see cref="SingboxConfigBuilder"/>: она чистая и потому
/// проверяется тестами без Windows и без ядра.
/// </remarks>
public sealed class Tun : IDisposable
{
    /// <summary>Строка лога ядра; уже с префиксом <c>[tun] </c>.</summary>
    /// <remarks>
    /// Приходит из потока-читателя, а не из потока интерфейса: маршалинг в UI —
    /// забота подписчика, как и у XrayRunner.
    /// </remarks>
    public event Action<string>? Log;

    /// <summary>Туннель поднят / снят.</summary>
    public event Action<bool>? StateChanged;

    private readonly object _lock = new object();
    private Process? _proc;

    /// <summary>
    /// Считаем ли мы туннель поднятым прямо сейчас.
    /// </summary>
    /// <remarks>
    /// Отдельный флаг, а не «процесс жив»: после неудачного <see cref="Stop"/>
    /// sing-box жив, и врать интерфейсу «снято» нельзя — там же, в Swift-версии
    /// (core-swift/Tun.swift), состояние по этой же причине держится флагом.
    /// </remarks>
    private bool _running;

    public bool Running
    {
        get
        {
            lock (_lock)
            {
                return _running;
            }
        }
    }

    /// <summary>
    /// Поднять туннель: запустить sing-box поверх уже работающего SOCKS Xray.
    /// </summary>
    /// <exception cref="UnauthorizedAccessException">Нет прав администратора.</exception>
    /// <exception cref="FileNotFoundException">Не скачан sing-box или wintun.dll.</exception>
    public void Start(Server server, int socksPort, string splitMode, IReadOnlyList<string> splitApps)
    {
        if (!Elevation.IsAdmin)
        {
            // Текст видит пользователь — переносится дословно из Python.
            throw new UnauthorizedAccessException("TUN-режим требует прав администратора.");
        }

        var exe = Paths.SingboxExe;
        if (!File.Exists(exe))
        {
            throw new FileNotFoundException($"Не найден sing-box: {exe}. Нажми «Скачать TUN».");
        }
        if (!File.Exists(Paths.WintunDll))
        {
            throw new FileNotFoundException("Не найден wintun.dll. Нажми «Скачать TUN».");
        }

        // Прошлая сессия могла не закрыть себя сама: sing-box умер, StateChanged
        // уже пришёл, а Stop() никто не позвал. Без этого второй Start поднял бы
        // ещё один процесс и поток-читатель поверх висящего (см. Tun.swift).
        // Stop() зовём снаружи блокировки: он шлёт события, а подписчик из UI
        // ходит через диспетчер и под захваченным замком мог бы встать намертво.
        Process? previous;
        lock (_lock)
        {
            previous = _proc;
        }
        if (previous != null)
        {
            Stop();
        }

        var ips = ResolveIps(server.Address);
        if (ips.Count == 0)
        {
            Log?.Invoke($"[tun] не удалось определить IP сервера {server.Address}, маршрут-исключение пуст");
        }
        else
        {
            Log?.Invoke($"[tun] обход для IP сервера: {string.Join(", ", ips)}");
        }

        if (splitMode != SplitMode.Off && splitApps.Count > 0)
        {
            var what = splitMode == SplitMode.Exclude ? "мимо VPN" : "через VPN";
            Log?.Invoke($"[tun] раздельный туннель: {what} — {string.Join(", ", splitApps)}");
        }

        // Путь до xray.exe отдаём в конфиг явно: правило process_path выводит сам
        // Xray из туннеля и тем разрывает петлю в режиме «Авто».
        var cfg = SingboxConfigBuilder.Build(socksPort, ips, Paths.XrayExe, "warn", splitMode, splitApps);
        var cfgPath = Paths.SingboxConfigFile;
        File.WriteAllText(cfgPath, cfg.ToJsonString(ConfigJson), Utf8NoBom);

        var psi = new ProcessStartInfo
        {
            FileName = exe,
            // Рядом обязан лежать wintun.dll: sing-box грузит его из рабочей
            // папки процесса, а не из папки с exe.
            WorkingDirectory = Paths.BinDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add("run");
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add(cfgPath);

        var proc = Process.Start(psi);
        if (proc == null)
        {
            throw new IOException($"Не удалось запустить sing-box: {exe}");
        }

        // Job-объект: если приложение снимут из диспетчера задач, ядро ОС само
        // прибьёт sing-box, и туннель не останется поднятым без хозяина.
        ProcessJob.Shared.Assign(proc);

        // Ввод ядру не нужен: закрываем сразу, иначе оно может ждать stdin.
        // Это замена stdin=DEVNULL из Python.
        proc.StandardInput.Close();

        lock (_lock)
        {
            _proc = proc;
            _running = true;
        }

        // PID на диск — чтобы следующий запуск приложения смог прибрать за собой,
        // если этот процесс переживёт нас (см. CleanupStray).
        try
        {
            File.WriteAllText(
                Paths.PidFile("singbox.pid"),
                proc.Id.ToString(CultureInfo.InvariantCulture),
                Utf8NoBom);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Не смогли записать след — уборка сирот не сработает, но туннель
            // поднимать это не мешает.
        }

        // Оба потока ядра читаем одинаково: в Python stderr сливался в stdout
        // (stderr=STDOUT), а .NET такого слияния не умеет — вместо него два
        // событийных читателя. Порядок строк между потоками при этом не
        // гарантирован, но у sing-box логи идут в один поток.
        proc.OutputDataReceived += OnOutput;
        proc.ErrorDataReceived += OnOutput;
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        Log?.Invoke("[tun] sing-box запущен (поднимаю TUN-адаптер)…");
        StateChanged?.Invoke(true);

        var waiter = new Thread(() => WaitAndReport(proc));
        waiter.IsBackground = true;
        waiter.Start();
    }

    private void OnOutput(object sender, DataReceivedEventArgs e)
    {
        // На EOF потока приходит null — это не строка лога, а конец чтения.
        var line = e.Data;
        if (!string.IsNullOrEmpty(line))
        {
            Log?.Invoke("[tun] " + line);
        }
    }

    /// <summary>
    /// Дождаться конца процесса и доложить о нём — ровно один раз.
    /// </summary>
    /// <remarks>
    /// <c>WaitForExit()</c> без таймаута ждёт ещё и слива обоих потоков вывода,
    /// поэтому строка «завершился» встаёт после всех строк ядра, а не посреди.
    ///
    /// О смене состояния докладывает тот, кто первым перевёл флаг в false:
    /// иначе после Stop() интерфейс получал бы StateChanged(false) дважды —
    /// от Stop() и отсюда. Свой ли это ещё процесс, сверяем по идентичности
    /// объекта, а не по флагу «идёт остановка»: флаг пришлось бы снимать, и
    /// поток, проснувшийся не мгновенно, успел бы увидеть его снятым
    /// (тот же приём в Tun.swift).
    /// </remarks>
    private void WaitAndReport(Process proc)
    {
        proc.WaitForExit();

        int code;
        try
        {
            code = proc.ExitCode;
        }
        catch (InvalidOperationException)
        {
            code = -1;
        }
        Log?.Invoke($"[tun] sing-box завершился (код {code})");

        bool report;
        lock (_lock)
        {
            report = ReferenceEquals(_proc, proc) && _running;
            if (report)
            {
                _running = false;
            }
        }
        if (report)
        {
            StateChanged?.Invoke(false);
        }
    }

    /// <summary>
    /// Снять sing-box. <c>true</c> — он снят; <c>false</c> — пережил остановку.
    /// </summary>
    /// <remarks>
    /// Тот же контракт возврата у macOS-версии (<c>Tun.stop()</c> в
    /// core-swift): там правду о снятии добывает ответ привилегированного
    /// демона, здесь — состояние своего же процесса. Общий у них смысл: пока
    /// sing-box жив, TUN-адаптер поднят и маршруты держатся, и интерфейс не
    /// имеет права показать «Отключено» — главное окно решает это по возврату.
    /// </remarks>
    public bool Stop()
    {
        Process? proc;
        lock (_lock)
        {
            proc = _proc;
        }
        if (proc == null)
        {
            return true;
        }

        if (!proc.HasExited)
        {
            Log?.Invoke("[tun] останавливаю sing-box (маршруты вернутся сами)…");
            try
            {
                // На Windows terminate() из Python — это и есть TerminateProcess,
                // отдельной «мягкой» ступени тут не существует; общее время
                // ожидания (7 + 3 секунды) сохранено как было. Дерево процессов
                // снимаем целиком: sing-box может держать вспомогательные.
                proc.Kill(entireProcessTree: true);
                if (!proc.WaitForExit(7000))
                {
                    proc.Kill(entireProcessTree: true);
                    proc.WaitForExit(3000);
                }
            }
            catch (Exception e)
            {
                Log?.Invoke($"[tun] ошибка остановки: {e.Message}");
            }
        }

        if (!proc.HasExited)
        {
            // Ручку на живом процессе не отпускаем: иначе Running врал бы
            // false, pid-файл ушёл бы вместе с единственным следом, и убрать
            // за собой не смог бы даже следующий запуск (см. CleanupStray).
            Log?.Invoke("[tun] ТРЕВОГА: sing-box пережил остановку — туннель ещё держит маршруты");
            return false;
        }

        bool report;
        lock (_lock)
        {
            report = ReferenceEquals(_proc, proc);
            if (report)
            {
                _proc = null;
                // Поток-читатель мог доложить о смерти раньше нас — тогда флаг
                // уже снят и второй раз о том же говорить незачем.
                report = _running;
                _running = false;
            }
        }

        TryDelete(Paths.PidFile("singbox.pid"));
        if (report)
        {
            StateChanged?.Invoke(false);
        }
        return true;
    }

    /// <summary>Брошенный <see cref="Tun"/> снимает туннель.</summary>
    /// <remarks>
    /// Process.Dispose здесь не зовём: тот же объект до самого EOF читает поток
    /// вывода, и гонка обернулась бы ObjectDisposedException прямо в Stop().
    /// Дескриптор освободит сборщик, а настоящую страховку от осиротевшего
    /// ядра даёт <see cref="ProcessJob"/>.
    /// </remarks>
    public void Dispose()
    {
        Stop();
    }

    // ------------------------------------------------------------------
    // Резолв IP сервера (для обходного маршрута)
    // ------------------------------------------------------------------

    /// <summary>Список IPv4-адресов хоста. Если host уже IP — вернуть его.</summary>
    /// <remarks>
    /// Только IPv4 и только он: конфиг клеит к каждому адресу маску <c>/32</c>,
    /// и IPv6 сюда попасть не должен. Пустой список — не ошибка: правило
    /// <c>process_path</c> на сам Xray в конфиге sing-box выводит его из
    /// туннеля и без списка исключений.
    /// </remarks>
    public static List<string> ResolveIps(string host)
    {
        var result = new List<string>();
        if (string.IsNullOrWhiteSpace(host))
        {
            return result;
        }

        if (IPAddress.TryParse(host, out var literal))
        {
            // Уже адрес, а не имя: резолвить нечего. IPv6-литерал отбрасываем
            // молча — так же вёл себя Python (inet_aton его не принимал, а
            // getaddrinfo с AF_INET по нему ничего не возвращал).
            if (literal.AddressFamily == AddressFamily.InterNetwork)
            {
                result.Add(host);
            }
            return result;
        }

        try
        {
            var found = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var address in Dns.GetHostAddresses(host))
            {
                if (address.AddressFamily == AddressFamily.InterNetwork)
                {
                    found.Add(address.ToString());
                }
            }
            result.AddRange(found);
        }
        catch (Exception)
        {
            // Имя не резолвится (нет сети, DNS перехвачен) — молча пустой
            // список: туннель всё равно можно поднять.
        }
        return result;
    }

    // ------------------------------------------------------------------
    // Уборка ядер, переживших прошлый запуск
    // ------------------------------------------------------------------

    // временно: сироты от Python-версии, убрать после 2 релизов.
    //
    // Основную работу теперь делает ProcessJob: ядро ОС само снимает ядра,
    // когда закрывается последний дескриптор job-объекта, то есть даже если
    // приложение сняли из диспетчера задач. Но после обновления с Python-версии
    // на диске могут лежать ЕЁ pid-файлы и работать ЕЁ процессы — про job они
    // ничего не знают, и убрать их некому, кроме этого кода.
    private static readonly (string File, string Image, string What)[] Cores =
    {
        // Порядок важен: сначала sing-box. Если снять сперва Xray, оставшийся
        // TUN продолжит забирать весь трафик системы и отдавать его в мёртвый
        // прокси — снаружи это выглядит как «интернет пропал».
        ("singbox.pid", "sing-box", "TUN-адаптер"),
        ("xray.pid", "xray", "соединение с сервером"),
    };

    /// <summary>Прибить ядра, пережившие прошлый запуск приложения.</summary>
    /// <remarks>
    /// Зачем. И Xray, и sing-box — отдельные процессы, а в TUN-режиме ещё и с
    /// правами администратора. Если приложение закрылось аварийно или его сняли
    /// из диспетчера, ядра остаются работать сами по себе: туннель поднят, но
    /// управлять им уже нечем — не отключить и не переключить сервер. А если
    /// Xray при этом успел умереть, а sing-box нет, TUN отдаёт весь трафик
    /// системы в никуда, и снаружи это выглядит как «интернет пропал».
    /// </remarks>
    /// <returns><c>true</c>, если что-то прибрали.</returns>
    public static bool CleanupStray(Action<string>? log)
    {
        var cleaned = false;
        var failed = false;

        foreach (var core in Cores)
        {
            var file = Paths.PidFile(core.File);
            if (!File.Exists(file))
            {
                continue;
            }

            int pid;
            try
            {
                var text = File.ReadAllText(file).Trim();
                if (!int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out pid))
                {
                    TryDelete(file);
                    continue;
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                TryDelete(file);
                continue;
            }

            if (!ProcessMatches(pid, core.Image))
            {
                TryDelete(file);   // процесс уже завершился штатно
                continue;
            }

            log?.Invoke($"[*] С прошлого запуска остался {core.Image} (PID {pid}) — держит {core.What}, убираю.");
            try
            {
                using var stray = Process.GetProcessById(pid);
                stray.Kill(entireProcessTree: true);
                stray.WaitForExit(5000);
            }
            catch (Exception e)
            {
                log?.Invoke($"[!] Не удалось: {e.Message}");
            }

            if (ProcessMatches(pid, core.Image))
            {
                failed = true;
            }
            else
            {
                TryDelete(file);
                cleaned = true;
            }
        }

        if (failed)
        {
            log?.Invoke("[!] Не хватило прав снять зависшее ядро. Запусти SCVPN от имени " +
                        "администратора — или перезагрузись, если интернет не работает.");
        }
        else if (cleaned)
        {
            log?.Invoke("[*] Зависшие ядра убраны, маршруты вернулись.");
        }
        return cleaned;
    }

    /// <summary>
    /// Жив ли процесс с таким PID и это действительно нужный нам образ.
    /// </summary>
    /// <remarks>
    /// Имя образа проверяем обязательно: номера процессов переиспользуются, и
    /// без этой сверки мы могли бы прибить чужой процесс, случайно получивший
    /// тот же. Python сравнивал подстрокой по выводу tasklist в cp866; здесь
    /// имя приходит от самой ОС и сравнивается целиком — «xray-helper» под
    /// раздачу уже не попадёт. Расширения в ProcessName нет, поэтому и в
    /// таблице выше образы записаны без «.exe».
    /// </remarks>
    private static bool ProcessMatches(int pid, string image)
    {
        try
        {
            using var proc = Process.GetProcessById(pid);
            if (proc.HasExited)
            {
                return false;
            }
            return string.Equals(proc.ProcessName, image, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            // ArgumentException — такого PID уже нет; InvalidOperationException —
            // процесс умер между запросом и чтением имени. И то и другое значит
            // «прибирать нечего».
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    // Конфиг читает ядро, а не браузер: экранировать не-ASCII (имя пользователя
    // в пути до xray.exe вполне бывает кириллическим) незачем. Это же поведение
    // было у Python: json.dumps(ensure_ascii=False, indent=2).
    private static readonly JsonSerializerOptions ConfigJson = new JsonSerializerOptions
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    // Без BOM: его не ждёт ни sing-box, ни наш же читатель pid-файлов.
    private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
}
