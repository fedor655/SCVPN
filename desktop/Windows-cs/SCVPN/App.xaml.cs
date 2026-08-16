using System.IO;
using System.Windows;
using System.Windows.Threading;
using SCVPN.Native;

namespace SCVPN;

/// <summary>
/// Точка входа. Соответствует run.py и run_app() из ui/main_window.py.
/// </summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Paths.EnsureDirs();

        // Необработанное исключение в WPF закрывает приложение молча: окно
        // просто исчезает. При поднятом TUN это худший из возможных исходов —
        // маршруты остались бы на мёртвом туннеле. Поэтому ловим, пишем на
        // диск и говорим вслух.
        DispatcherUnhandledException += OnUnhandledException;

        var window = new Views.MainWindow();
        MainWindow = window;
        window.Show();
    }

    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            var path = Path.Combine(Paths.LogDir, "crash.log");
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {e.Exception}\n\n");
        }
        catch (IOException)
        {
            // Не смогли записать — не та беда, из-за которой стоит падать снова.
        }

        MessageBox.Show(
            $"Непредвиденная ошибка:\n\n{e.Exception.Message}\n\n" +
            "Подробности записаны в logs/crash.log рядом с настройками.",
            "SCVPN", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
