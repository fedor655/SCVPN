using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace SCVPN.Native;

/// <summary>
/// Управление системным прокси Windows.
///
/// Windows хранит настройки прокси в реестре:
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings</c>.
/// Мы выставляем ProxyServer на наш локальный HTTP-вход (127.0.0.1:порт) и
/// поднимаем флаг ProxyEnable. При отключении — всё возвращаем как было.
///
/// Это «режим как в браузере»: его уважают почти все приложения, права админа
/// не нужны. TUN-режим (весь трафик) — отдельный модуль.
/// </summary>
public static class SystemProxy
{
    private const string InternetSettings = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    // Обход прокси для локальных адресов.
    private const string Bypass = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;192.168.*;<local>";

    // Сказать Windows перечитать настройки прокси (WinINet).
    private const int InternetOptionSettingsChanged = 39;
    private const int InternetOptionRefresh = 37;

    /// <summary>Включить системный HTTP-прокси на host:port.</summary>
    public static void Enable(string host = "127.0.0.1", int port = 10809)
    {
        SaveBackupIfAbsent();

        using RegistryKey? key = Registry.CurrentUser.CreateSubKey(InternetSettings, writable: true);
        if (key is null)
            throw new InvalidOperationException("Не удалось открыть настройки прокси в реестре.");

        key.SetValue("ProxyEnable", 1, RegistryValueKind.DWord);
        // Порт — через инвариантную культуру: русская локаль умеет вписать в
        // число разделитель разрядов, а реестру нужен ровно "127.0.0.1:10809".
        key.SetValue("ProxyServer", host + ":" + port.ToString(CultureInfo.InvariantCulture), RegistryValueKind.String);
        key.SetValue("ProxyOverride", Bypass, RegistryValueKind.String);

        Refresh();
    }

    /// <summary>Выключить системный прокси, вернув то, что стояло до нас.</summary>
    public static void Disable()
    {
        try
        {
            if (!RestoreBackup())
            {
                // Сохранённого состояния нет (первая версия приложения не
                // умела его писать, либо файл потеряли) — ведём себя как
                // Python-версия: просто гасим флаг.
                using RegistryKey? key = Registry.CurrentUser.OpenSubKey(InternetSettings, writable: true);
                key?.SetValue("ProxyEnable", 0, RegistryValueKind.DWord);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            // Ветки нет или её не дают править — гасить нечего.
        }

        Refresh();
    }

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using RegistryKey? key = Registry.CurrentUser.OpenSubKey(InternetSettings, writable: false);
                object? value = key?.GetValue("ProxyEnable");
                return value is not null && Convert.ToInt32(value, CultureInfo.InvariantCulture) != 0;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                             or System.Security.SecurityException
                                             or FormatException or InvalidCastException)
            {
                return false;
            }
        }
    }

    // ------------------------------------------------------------------
    // Сохранение прежних настроек
    // ------------------------------------------------------------------
    // Python-версия хранила прежнее состояние только в голове пользователя:
    // включили прокси, приложение упало или его сняли из диспетчера — и в
    // системе навсегда остался наш 127.0.0.1:10809, а интернет «пропал».
    // Поэтому старые значения уходят на диск, а не в поле в памяти: файл
    // переживает аварийное закрытие, ради которого всё и затевалось.

    private static string BackupPath => Path.Combine(Paths.DataDir, "sysproxy_backup.json");

    private sealed class ProxyBackup
    {
        // null означает «значения в реестре не было» — при восстановлении
        // такое значение надо удалить, а не записать нулём: пустой ProxyServer
        // и отсутствующий ProxyServer для WinINet не одно и то же.
        [JsonPropertyName("proxy_enable")] public int? ProxyEnable { get; set; }
        [JsonPropertyName("proxy_server")] public string? ProxyServer { get; set; }
        [JsonPropertyName("proxy_override")] public string? ProxyOverride { get; set; }
    }

    private static void SaveBackupIfAbsent()
    {
        // Файл уже есть — значит, прокси включали и не выключали. Второй
        // Enable (переподключение, смена порта) не должен записать поверх
        // чужих настроек наши же: тогда Disable «вернул» бы 127.0.0.1 навсегда.
        if (File.Exists(BackupPath))
            return;

        var backup = new ProxyBackup();
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(InternetSettings, writable: false);
            if (key is not null)
            {
                object? enable = key.GetValue("ProxyEnable");
                if (enable is not null)
                    backup.ProxyEnable = Convert.ToInt32(enable, CultureInfo.InvariantCulture);
                backup.ProxyServer = key.GetValue("ProxyServer") as string;
                backup.ProxyOverride = key.GetValue("ProxyOverride") as string;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
                                         or System.Security.SecurityException
                                         or FormatException or InvalidCastException)
        {
            // Прочитать не вышло — сохраним пустой снимок: это честное
            // «до нас прокси не было», и Disable уберёт наши значения совсем.
        }

        try
        {
            Paths.EnsureDirs();
            File.WriteAllText(BackupPath, JsonSerializer.Serialize(backup, BackupOptions));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Не записали — Disable свалится на поведение Python-версии.
        }
    }

    private static readonly JsonSerializerOptions BackupOptions = new() { WriteIndented = true };

    /// <summary>Вернуть сохранённые настройки. false — сохранённого нет.</summary>
    private static bool RestoreBackup()
    {
        ProxyBackup? backup = null;
        try
        {
            if (File.Exists(BackupPath))
                backup = JsonSerializer.Deserialize<ProxyBackup>(File.ReadAllText(BackupPath));
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            backup = null;
        }
        if (backup is null)
            return false;

        using (RegistryKey? key = Registry.CurrentUser.CreateSubKey(InternetSettings, writable: true))
        {
            if (key is null)
                return false;

            if (backup.ProxyEnable is int enable)
                key.SetValue("ProxyEnable", enable, RegistryValueKind.DWord);
            else
                key.DeleteValue("ProxyEnable", throwOnMissingValue: false);

            SetOrDelete(key, "ProxyServer", backup.ProxyServer);
            SetOrDelete(key, "ProxyOverride", backup.ProxyOverride);
        }

        // Снимок отработал — убираем, иначе следующий Enable решит, что прокси
        // уже включён кем-то, и сохранит наши значения как «прежние».
        try
        {
            File.Delete(BackupPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Останется висеть — хуже, чем ничего, но настройки уже вернули.
        }
        return true;
    }

    private static void SetOrDelete(RegistryKey key, string name, string? value)
    {
        if (value is null)
            key.DeleteValue(name, throwOnMissingValue: false);
        else
            key.SetValue(name, value, RegistryValueKind.String);
    }

    // ------------------------------------------------------------------
    // WinINet
    // ------------------------------------------------------------------
    private static void Refresh()
    {
        try
        {
            // Оба вызова обязательны и именно в этом порядке: SETTINGS_CHANGED
            // говорит «настройки изменились», REFRESH — «перечитай их прямо
            // сейчас». Без второго уже открытые браузеры продолжают ходить
            // мимо прокси до перезапуска.
            InternetSetOptionW(IntPtr.Zero, InternetOptionSettingsChanged, IntPtr.Zero, 0);
            InternetSetOptionW(IntPtr.Zero, InternetOptionRefresh, IntPtr.Zero, 0);
        }
        catch (DllNotFoundException)
        {
            // wininet.dll есть в любой Windows; если нет — реестр мы уже
            // поправили, разница лишь в том, что применится не мгновенно.
        }
        catch (EntryPointNotFoundException)
        {
        }
    }

    [DllImport("wininet.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InternetSetOptionW(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
