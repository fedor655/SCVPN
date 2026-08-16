using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Security.Principal;

namespace SCVPN.Native;

/// <summary>
/// Права администратора: TUN-режим создаёт сетевой адаптер и правит таблицу
/// маршрутов, без повышения это не делается.
///
/// Имена и контракт общие с macOS-версией (<c>native/tun.py</c> там же), только
/// реализация другая: здесь UAC, там установка привилегированного демона через
/// launchd.
/// </summary>
public static class Elevation
{
    public const string PrivilegeQuestion =
        "TUN-режим (весь трафик) требует прав администратора.\n" +
        "Перезапустить приложение от имени администратора?";

    /// <summary>
    /// Что пошло не так в последнем <see cref="AcquirePrivilege"/>, если тот
    /// вернул не "restart".
    /// </summary>
    /// <remarks>
    /// Контракт <see cref="AcquirePrivilege"/> -&gt; string (общий с macOS) не
    /// трогаем — это просто карман для причины, которую иначе было бы некуда
    /// деть: главное окно показало бы одну и ту же зашитую фразу и на отказе
    /// пользователя от UAC, и на том, что перезапускать оказалось нечего.
    /// </remarks>
    public static string LastError { get; private set; } = string.Empty;

    public static bool IsAdmin
    {
        get
        {
            try
            {
                using WindowsIdentity identity = WindowsIdentity.GetCurrent();
                return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException)
            {
                return false;
            }
        }
    }

    /// <summary>
    /// Перезапустить приложение с правами администратора (вызовет UAC).
    /// </summary>
    /// <returns>
    /// true, если запрос на повышение отправлен — текущий процесс надо
    /// закрыть. false — если не вышло; причину смотри в <see cref="LastError"/>.
    /// </returns>
    public static bool RelaunchAsAdmin()
    {
        string? exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            LastError = "не найден исполняемый файл для перезапуска.";
            return false;
        }

        var info = new ProcessStartInfo
        {
            FileName = exe,
            // Verb работает только вместе с UseShellExecute: без него .NET
            // запускает процесс напрямую, мимо ShellExecuteEx, и повышения не
            // происходит — приложение просто откроется вторым обычным окном.
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = Paths.Root,
        };

        // Те же аргументы, что у текущего процесса. Через ArgumentList, а не
        // склейкой строки: кавычки вокруг путей с пробелами расставит сам .NET,
        // в Python это приходилось делать руками.
        string[] args = Environment.GetCommandLineArgs();
        for (int i = 1; i < args.Length; i++)
            info.ArgumentList.Add(args[i]);

        try
        {
            Process.Start(info);
            LastError = string.Empty;
            return true;
        }
        catch (Win32Exception ex)
        {
            LastError = Describe(ex);
            return false;
        }
        catch (Exception ex) when (ex is InvalidOperationException or PlatformNotSupportedException or ObjectDisposedException)
        {
            LastError = ex.GetType().Name + ": " + ex.Message;
            return false;
        }
    }

    /// <summary>Человеческий текст для кода ошибки запуска.</summary>
    /// <remarks>
    /// Самые частые причины отказа, чтобы <see cref="LastError"/> говорил по
    /// существу, а не «не получилось». Тексты перенесены из Python-версии
    /// (_SHELL_EXECUTE_ERRORS), но коды другие: Python звал ShellExecuteW и
    /// разбирал её собственные SE_ERR_*, а Process.Start отдаёт нормальный
    /// код Win32. Совпадение номеров тут случайно и опасно — отказ от UAC это
    /// SE_ERR_ACCESSDENIED = 5 у ShellExecute и ERROR_CANCELLED = 1223 у Win32,
    /// а Win32 5 означает совсем другое.
    /// </remarks>
    private static string Describe(Win32Exception ex)
    {
        switch (ex.NativeErrorCode)
        {
            case 1223: // ERROR_CANCELLED
                return "запрос на права администратора отклонён (нажато «Нет» в диалоге UAC).";
            case 2: // ERROR_FILE_NOT_FOUND
                return "не найден исполняемый файл для перезапуска.";
            case 3: // ERROR_PATH_NOT_FOUND
                return "не найден путь для перезапуска.";
            case 5: // ERROR_ACCESS_DENIED
                return "система запретила запуск: нет доступа к файлу приложения.";
            case 8: // ERROR_NOT_ENOUGH_MEMORY
                return "не хватило памяти для запуска.";
            case 14: // ERROR_OUTOFMEMORY
                return "не хватило памяти или ресурсов операционной системы.";
            case 32: // ERROR_SHARING_VIOLATION
                return "файл занят другим процессом.";
            case 1155: // ERROR_NO_ASSOCIATION
                return "для этого файла не назначено приложение, которое могло бы его открыть.";
            case 1260: // ERROR_ACCESS_DISABLED_BY_POLICY
                return "запуск от имени администратора запрещён политикой безопасности Windows.";
            default:
                return $"не удалось перезапустить, код ошибки {ex.NativeErrorCode}: {ex.Message}";
        }
    }

    /// <summary>Можно ли прямо сейчас поднять TUN. На Windows это права администратора.</summary>
    public static bool Privileged() => IsAdmin;

    /// <summary>
    /// Запросить права. "restart" — процесс надо закрыть, поднимется новый.
    /// </summary>
    public static string AcquirePrivilege() => RelaunchAsAdmin() ? "restart" : "failed";
}
