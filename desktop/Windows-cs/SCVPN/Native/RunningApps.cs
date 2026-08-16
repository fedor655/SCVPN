using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;

namespace SCVPN.Native;

/// <summary>
/// Список запущенных приложений для правил раздельного туннелирования.
///
/// sing-box сопоставляет соединение с процессом-владельцем по имени
/// исполняемого файла, поэтому здесь нужны именно имена .exe, а не заголовки
/// окон.
/// </summary>
public static class RunningApps
{
    public const string ManualHint = "Имя исполняемого файла (например, Telegram.exe):";

    // Системные процессы, которые в списке только мешают.
    private static readonly HashSet<string> Hidden = new(StringComparer.OrdinalIgnoreCase)
    {
        "system", "system idle process", "registry", "memory compression", "svchost.exe",
        "csrss.exe", "wininit.exe", "winlogon.exe", "services.exe", "lsass.exe",
        "smss.exe", "fontdrvhost.exe", "dwm.exe", "ctfmon.exe", "sihost.exe",
        "taskhostw.exe", "runtimebroker.exe", "searchhost.exe", "conhost.exe",
        "dllhost.exe", "spoolsv.exe", "audiodg.exe", "wudfhost.exe",
        // Список выше перенесён из Python дословно, а он писался под вывод
        // tasklist. Process.ProcessName зовёт бездействие системы (PID 0) не
        // "System Idle Process", а "Idle" — под старый список оно не подпадает
        // и вылезло бы в выборе приложений.
        "idle",
    };

    /// <summary>Имена запущенных .exe, без системной мелочи и дубликатов.</summary>
    /// <remarks>
    /// Через <see cref="Process.GetProcesses()"/>, а не разбором вывода
    /// tasklist: тот же ответ без запуска процесса и без возни с кодировкой
    /// cp866, на которой русские имена в Python приходилось чинить
    /// errors="replace".
    /// </remarks>
    public static List<string> List()
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        Process[] processes;
        try
        {
            processes = Process.GetProcesses();
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception)
        {
            // Совсем не дали перечислить — пустой список честнее исключения:
            // в диалоге останется ручной ввод по ManualHint.
            return new List<string>();
        }

        foreach (Process process in processes)
        {
            try
            {
                string name = process.ProcessName;
                if (name.Length == 0)
                    continue;
                // Часть процессов защищена или успевает завершиться между
                // перечислением и чтением свойства. Глотаем поштучно: иначе
                // один защищённый процесс уносил бы весь список.
                if (Hidden.Contains(name))
                    continue;
                // ProcessName приходит без расширения, а правилу sing-box
                // нужно ровно то имя, которое видит система: "Telegram.exe".
                string exe = name + ".exe";
                if (Hidden.Contains(exe))
                    continue;
                names.Add(exe);
            }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
            {
            }
            finally
            {
                process.Dispose();
            }
        }

        return names.OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>Привести введённое руками имя к виду, который поймёт правило sing-box.</summary>
    public static string Normalize(string name)
    {
        string result = name.Trim();
        if (result.Length > 0 && !result.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            result += ".exe";
        return result;
    }
}
