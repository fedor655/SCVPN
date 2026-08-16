using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using SCVPN.Native;

namespace SCVPN.Core;

/// <summary>
/// Запуск и остановка ядра xray.exe.
/// </summary>
/// <remarks>
/// Пишет конфиг в отдельный файл (xray_running.json — его можно открыть и
/// посмотреть, чем именно поднялся туннель), запускает ядро дочерним процессом
/// без чёрного окна консоли, читает его вывод в фоне и отдаёт строки событием
/// <see cref="Log"/>.
///
/// Класс намеренно не знает про WPF: события прилетают из чужих потоков, и
/// раскладывать их по Dispatcher — забота интерфейса, а не этого файла.
/// </remarks>
public sealed class XrayRunner : IDisposable
{
    private const string PidFileName = "xray.pid";

    private readonly object _lock = new object();
    private Process? _proc;

    public event Action<string>? Log;
    public event Action<bool>? StateChanged;

    public bool Running
    {
        get
        {
            lock (_lock)
            {
                if (_proc == null) return false;
                try
                {
                    return !_proc.HasExited;
                }
                catch (InvalidOperationException)
                {
                    return false;
                }
            }
        }
    }

    public void Start(JsonObject config)
    {
        if (Running) Stop();

        string exe = Paths.XrayExe;
        if (!File.Exists(exe))
        {
            // Текст видит пользователь — переносится дословно из Python-версии.
            throw new FileNotFoundException(
                $"Не найдено ядро Xray: {exe}\n" +
                "Скачай его кнопкой в приложении или положи xray.exe в папку bin/.");
        }

        Paths.EnsureDirs();
        string cfgPath = Paths.XrayConfigFile;
        // Без экранирования: ядру всё равно, а человеку читать имена серверов
        // с кириллицей и адреса со слэшами в виде \u04.. невозможно.
        // Кодировка — UTF-8 строго без BOM: с меткой xray не разбирает JSON.
        string json = config.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
        File.WriteAllText(cfgPath, json, new UTF8Encoding(false));

        var psi = new ProcessStartInfo
        {
            FileName = exe,
            // Рядом с bin/ лежат гео-базы: ядро ищет geoip.dat и geosite.dat
            // относительно рабочего каталога, а не относительно себя.
            WorkingDirectory = Paths.BinDir,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            CreateNoWindow = true,
            UseShellExecute = false,
        };
        // ArgumentList сам разбирается с кавычками: в пути к конфигу есть
        // %LOCALAPPDATA%, а там имя пользователя с пробелом — обычное дело.
        psi.ArgumentList.Add("run");
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add(cfgPath);

        var proc = new Process { StartInfo = psi };
        proc.OutputDataReceived += OnOutput;
        proc.ErrorDataReceived += OnOutput;

        proc.Start();
        // Привязка к job-объекту — сразу после старта: если приложение снимут
        // из диспетчера задач в следующую секунду, ядро должно умереть с ним.
        ProcessJob.Shared.Assign(proc);

        // Стандартный ввод ядру не нужен, но и наследовать консоль ему нельзя:
        // закрываем сразу, чтобы оно видело EOF, а не висело на чтении.
        proc.StandardInput.Close();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        lock (_lock)
        {
            _proc = proc;
        }

        // PID на диск — сироты от прошлой (Python) версии приложения ищутся
        // именно по этому файлу. Ошибку записи глотаем: работать это не мешает.
        try
        {
            // InvariantCulture: этот же файл читает Tun.CleanupStray разбором с
            // инвариантной культурой, и запись обязана быть ему по зубам.
            File.WriteAllText(
                Paths.PidFile(PidFileName),
                proc.Id.ToString(CultureInfo.InvariantCulture),
                new UTF8Encoding(false));
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }

        Log?.Invoke($"[core] запуск: {Path.GetFileName(exe)} run -c {Path.GetFileName(cfgPath)}");
        StateChanged?.Invoke(true);

        // О смерти ядра докладывает отдельный поток, а не событие Exited.
        // Слежение за выходом .NET включает внутри Start(), и ядро с битым
        // конфигом успевает умереть раньше, чем мы дошли бы до присваивания
        // _proc: обработчик не узнавал бы свой процесс, промолчал — и интерфейс
        // навсегда остался бы «подключено». Поток заводится последним, когда и
        // ссылка положена, и StateChanged(true) уже отправлен, поэтому
        // «завершилось» не может опередить «запустилось» (так же в Native/Tun.cs
        // и в XrayRunner.swift).
        var waiter = new Thread(() => WaitAndReport(proc));
        waiter.IsBackground = true;
        waiter.Start();
    }

    public void Stop()
    {
        Process? proc;
        lock (_lock)
        {
            proc = _proc;
            _proc = null;
        }
        if (proc == null) return;

        try
        {
            if (!proc.HasExited)
            {
                Log?.Invoke("[core] остановка ядра…");
                // На Windows «мягкой» остановки консольного процесса из .NET
                // нет: и terminate() Python-версии, и Kill() — это один и тот
                // же TerminateProcess. Пять секунд ждём на случай, если ядро
                // ещё дописывает лог, потом добиваем вместе с потомками.
                proc.Kill();
                if (!proc.WaitForExit(5000)) proc.Kill(entireProcessTree: true);
            }
        }
        catch (Exception e)
        {
            Log?.Invoke($"[core] ошибка остановки: {e.Message}");
        }

        try
        {
            File.Delete(Paths.PidFile(PidFileName));
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }

        // Process.Dispose здесь не зовём: WaitForExit(5000) с таймаутом НЕ
        // дожидается слива потоков вывода, а Dispose обрывает их чтение — в лог
        // не попали бы последние строки ядра, в которых и написана причина
        // падения. Дескриптор освободит сборщик, а страховку от осиротевшего
        // ядра даёт ProcessJob (то же решение в Native/Tun.cs).
        StateChanged?.Invoke(false);
    }

    public void Dispose()
    {
        Stop();
    }

    private void OnOutput(object sender, DataReceivedEventArgs e)
    {
        // null приходит при закрытии потока, пустые строки ядро сыплет само —
        // ни то, ни другое в лог пускать не за чем.
        if (!string.IsNullOrEmpty(e.Data)) Log?.Invoke(e.Data);
    }

    /// <summary>Дождаться конца процесса и доложить о нём.</summary>
    /// <remarks>
    /// WaitForExit() без таймаута дожидается, пока дочитаются асинхронные строки
    /// вывода. Иначе последние строки — а в них обычно и написана причина
    /// падения — пришли бы в лог уже после сообщения о завершении.
    ///
    /// Ждём снаружи замка: под ним сидит Running, а сам Stop() в это время
    /// вполне может ждать тот же процесс на другом потоке.
    /// </remarks>
    private void WaitAndReport(Process proc)
    {
        try
        {
            proc.WaitForExit();
            Log?.Invoke($"[core] процесс завершился (код {proc.ExitCode})");
        }
        catch (Exception)
        {
            Log?.Invoke("[core] процесс завершился");
        }

        // Пока мы ждали, Stop() мог уже поднять новое ядро. Сообщать о падении
        // чужого процесса нельзя — интерфейс погасил бы работающее соединение.
        // Ссылку не сбрасываем: Running и так вернёт false, зато Stop() потом
        // сам приберёт pid-файл.
        lock (_lock)
        {
            if (!ReferenceEquals(_proc, proc)) return;
        }

        StateChanged?.Invoke(false);
    }
}
