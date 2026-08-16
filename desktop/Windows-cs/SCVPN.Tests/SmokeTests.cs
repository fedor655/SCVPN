using System.Diagnostics;
using System.Text.Json.Nodes;
using SCVPN.Core;
using SCVPN.Native;
using Xunit;
using Xunit.Abstractions;

namespace SCVPN.Tests;

/// <summary>
/// Сквозная проверка на живой машине — порт smoke_test.py.
///
/// В обычный прогон не попадает: она трогает настоящие профили пользователя,
/// поднимает ядро и ходит в сеть. Запуск отдельно:
///
///     dotnet test --filter Category=Live
///
/// Шаги те же, что были в Python: архитектура, профили, конфиг Xray, проверка
/// конфига sing-box самим sing-box, реальный туннель с выходным IP. Чего не
/// хватает для шага — тот шаг сообщает об этом и не падает: «ядро не скачано»
/// это не поломка кода.
/// </summary>
[Trait("Category", "Live")]
public class SmokeTests
{
    private readonly ITestOutputHelper _out;

    public SmokeTests(ITestOutputHelper output)
    {
        _out = output;
    }

    /// <summary>
    /// Живые проверки не должны срабатывать при обычном <c>dotnet test</c>:
    /// они поднимают ядро, ходят в сеть и трогают настоящие профили.
    /// Атрибут Skip в xUnit 2 задаётся только константой, поэтому выключатель
    /// здесь — переменная окружения.
    /// </summary>
    private bool Live()
    {
        if (Environment.GetEnvironmentVariable("SCVPN_LIVE") == "1")
        {
            return true;
        }

        _out.WriteLine("Пропущено: живые проверки включаются переменной SCVPN_LIVE=1.");
        return false;
    }

    [Fact]
    public void Step0_environment()
    {
        if (!Live()) return;

        _out.WriteLine($"архитектура ОС:        {Arch.Host}");
        _out.WriteLine($"архитектура процесса:  {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}");
        _out.WriteLine($"эмуляция:              {Arch.Emulated}");
        _out.WriteLine($"bin/arch.txt:          {CoreDownloader.BinArch()}");
        _out.WriteLine($"ядро Xray установлено: {CoreDownloader.CorePresent()}");
        _out.WriteLine($"TUN установлен:        {CoreDownloader.TunPresent()}");
        _out.WriteLine($"права администратора:  {Elevation.IsAdmin}");
        _out.WriteLine($"данные:                {Paths.DataDir}");

        // Несовпадение архитектур — это именно провал, а не «ядра нет»: файлы
        // на месте, но запустить их система не сможет.
        if (File.Exists(Paths.XrayExe))
        {
            Assert.Equal(Arch.Host, CoreDownloader.BinArch());
        }
    }

    [Fact]
    public void Step1_profiles_are_readable()
    {
        if (!Live()) return;

        Profiles profiles = Store.LoadProfiles();
        List<Server> servers = profiles.AllServers();
        _out.WriteLine($"серверов: {servers.Count}");

        if (servers.Count == 0)
        {
            _out.WriteLine("Нет серверов — добавь подписку в приложении и запусти снова.");
            return;
        }

        Server target = Pick(servers);
        _out.WriteLine($"тестовый сервер: {target.Title} [{target.Address}:{target.Port}]");
    }

    [Fact]
    public void Step2_singbox_accepts_the_config_we_build()
    {
        if (!Live()) return;

        if (!File.Exists(Paths.SingboxExe))
        {
            _out.WriteLine("sing-box не установлен — пропускаю.");
            return;
        }

        JsonObject config = SingboxConfigBuilder.Build(
            10808, new List<string> { "93.184.216.34" }, Paths.XrayExe);
        string path = Path.Combine(Paths.DataDir, "_smoke_singbox.json");
        Paths.EnsureDirs();
        File.WriteAllText(path, config.ToJsonString());

        var psi = new ProcessStartInfo(Paths.SingboxExe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Paths.BinDir,
        };
        psi.ArgumentList.Add("check");
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add(path);

        using Process proc = Process.Start(psi)!;
        string output = proc.StandardOutput.ReadToEnd() + proc.StandardError.ReadToEnd();
        proc.WaitForExit(20000);

        _out.WriteLine(output.Trim());
        Assert.Equal(0, proc.ExitCode);
    }

    [Fact]
    public async Task Step3_a_real_tunnel_carries_traffic()
    {
        if (!Live()) return;

        if (!CoreDownloader.CorePresent())
        {
            _out.WriteLine("Ядро Xray не установлено — пропускаю.");
            return;
        }

        List<Server> servers = Store.LoadProfiles().AllServers();
        if (servers.Count == 0)
        {
            _out.WriteLine("Нет серверов — пропускаю.");
            return;
        }

        Server target = Pick(servers);
        string fingerprint = await FingerprintProbe.FindWorkingAsync(
            target, "auto", RouteMode.Global, false, s => _out.WriteLine("   " + s));
        _out.WriteLine($"рабочий отпечаток: {fingerprint}");

        Server probe = target.Clone();
        probe.Fingerprint = fingerprint;

        int socks = FreePort.Find(21080);
        int http = FreePort.Find(Math.Max(21081, socks + 1));
        var runner = new XrayRunner();
        try
        {
            runner.Start(XrayConfigBuilder.Build(probe, socks, http));
            await Task.Delay(2000);

            using var handler = new HttpClientHandler
            {
                Proxy = new System.Net.WebProxy($"http://127.0.0.1:{http}"),
                UseProxy = true,
            };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
            string ip = (await client.GetStringAsync(FingerprintProbe.ProbeUrl)).Trim();

            _out.WriteLine($"выходной IP: {ip}");
            Assert.NotEmpty(ip);
        }
        finally
        {
            runner.Stop();
            runner.Dispose();
        }
    }

    /// <summary>
    /// Reality поверх TCP — самый показательный случай: там и подбор
    /// отпечатка, и рукопожатие, из-за которого сервер обычно и не работает.
    /// </summary>
    private static Server Pick(List<Server> servers)
    {
        foreach (Server s in servers)
        {
            if (s.Network == "tcp" && s.Security == "reality")
            {
                return s;
            }
        }

        return servers[0];
    }
}
