using System;
using System.IO;

namespace SCVPN.Native;

/// <summary>
/// Все пути приложения в одном месте — чтобы было видно, где что лежит.
/// </summary>
/// <remarks>
/// Отличие от Python-версии: там была вилка «запуск из исходников / собранный
/// exe» (<c>sys.frozen</c>), и в режиме разработки данные лежали в <c>data/</c>
/// рядом с проектом. В .NET такой вилки нет — запуск всегда «собранный», —
/// поэтому режим разработки заменён переменной окружения
/// <c>SCVPN_DATA_DIR</c>: она же позволяет тестам увести запись во временную
/// папку, а не в настоящие профили пользователя (в Swift ради этого поля
/// сделаны изменяемыми, см. core-swift/Paths.swift).
///
/// Свойства считаются при каждом обращении, а не один раз при инициализации
/// типа: иначе подмена <c>SCVPN_DATA_DIR</c> из теста сработала бы только
/// если тест успел выставить её раньше первого чужого обращения к Paths.
///
/// Имена файлов на диске трогать нельзя — это файлы пользователя, оставшиеся
/// от Python-версии, и обновление обязано их подхватить.
/// </remarks>
public static class Paths
{
    /// <summary>Папка, из которой запущено приложение (рядом лежит exe).</summary>
    /// <remarks>
    /// <see cref="AppContext.BaseDirectory"/> оканчивается разделителем;
    /// срезаем его, чтобы путь можно было печатать в лог без «\\» в середине.
    /// Для склейки всё равно используется <see cref="Path.Combine(string, string)"/>.
    /// </remarks>
    public static string Root { get; } =
        Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);

    /// <summary>
    /// Папка с ядром и гео-базами (xray.exe, sing-box.exe, wintun.dll,
    /// geoip.dat, geosite.dat).
    /// </summary>
    /// <remarks>
    /// Рядом с приложением: установщик кладёт сюда бинарники, а приложение их
    /// только читает и перекачивает по кнопке. В %LOCALAPPDATA% их уносить
    /// нельзя — sing-box грузит wintun.dll из своей рабочей папки.
    /// </remarks>
    public static string BinDir => Path.Combine(Root, "bin");

    /// <summary>Папка с пользовательскими данными: профили, настройки, логи.</summary>
    /// <remarks>
    /// Рядом с exe писать нельзя: приложение стоит в Program Files. Если задана
    /// <c>SCVPN_DATA_DIR</c> — берём её (замена «режима разработки» из Python и
    /// точка подмены для тестов). Относительный путь в переменной считается от
    /// <see cref="Root"/>, а не от текущей папки процесса: у запущенного из
    /// ярлыка приложения текущая папка непредсказуема.
    /// </remarks>
    public static string DataDir
    {
        get
        {
            var custom = Environment.GetEnvironmentVariable("SCVPN_DATA_DIR");
            if (!string.IsNullOrWhiteSpace(custom))
            {
                // Path.Combine возвращает второй аргумент как есть, если он
                // абсолютный, — то есть эта строка покрывает оба случая.
                return Path.Combine(Root, custom.Trim());
            }

            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(local))
            {
                // Тот же запасной путь, что в Python: профиль пользователя.
                local = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            }

            return Path.Combine(local, "SCVPN");
        }
    }

    public static string LogDir => Path.Combine(DataDir, "logs");

    /// <summary>Серверы и подписки.</summary>
    public static string ProfilesFile => Path.Combine(DataDir, "profiles.json");

    /// <summary>Настройки приложения.</summary>
    public static string SettingsFile => Path.Combine(DataDir, "settings.json");

    /// <summary>Активный конфиг Xray — лежит на диске ради отладки.</summary>
    public static string XrayConfigFile => Path.Combine(DataDir, "xray_running.json");

    /// <summary>Активный конфиг sing-box (TUN-режим) — тоже ради отладки.</summary>
    public static string SingboxConfigFile => Path.Combine(DataDir, "singbox_running.json");

    // Расширение .exe зашито: TFM у проекта Windows-only, ветка «не nt» из
    // Python здесь недостижима.
    public static string XrayExe => Path.Combine(BinDir, "xray.exe");

    /// <summary>sing-box нужен только для TUN-режима: он поднимает TUN-адаптер.</summary>
    public static string SingboxExe => Path.Combine(BinDir, "sing-box.exe");

    /// <summary>Драйвер виртуального адаптера для TUN на Windows.</summary>
    public static string WintunDll => Path.Combine(BinDir, "wintun.dll");

    public static string GeoipDat => Path.Combine(BinDir, "geoip.dat");

    public static string GeositeDat => Path.Combine(BinDir, "geosite.dat");

    /// <summary>Архитектура бинарников, лежащих сейчас в <see cref="BinDir"/>.</summary>
    /// <remarks>
    /// Без метки нельзя отличить arm64-набор от x64: пользователь, обновившийся
    /// на ARM-машине, остался бы со старыми x64-ядрами и получил невнятную
    /// ошибку запуска вместо предложения скачать ядро (см. шаг 3 плана
    /// docs/windows-arm64-plan.md). Отсутствие файла означает «x64»: так вёл
    /// себя bin/, собранный до появления метки.
    /// </remarks>
    public static string ArchStamp => Path.Combine(BinDir, "arch.txt");

    /// <summary>Иконка приложения файлом на диске.</summary>
    /// <remarks>
    /// Окну иконка достаётся ресурсом сборки (pack-URI), но части Windows API
    /// нужен именно файл. Файла может не оказаться — вызывающий обязан
    /// проверить существование, как это делал run_app() в Python.
    /// </remarks>
    public static string IconFile => Path.Combine(Root, "Assets", "scvpn.ico");

    /// <summary>Файл с PID запущенного ядра: <c>xray.pid</c> или <c>singbox.pid</c>.</summary>
    /// <remarks>
    /// Оба ядра — отдельные процессы и переживают аварийное закрытие
    /// приложения: туннель поднят, а управлять им уже нечем. Следующий запуск
    /// читает эти файлы и снимает осиротевшие процессы (Tun.CleanupStray).
    /// </remarks>
    public static string PidFile(string name) => Path.Combine(DataDir, name);

    /// <summary>Создать рабочие папки, если их ещё нет.</summary>
    public static void EnsureDirs()
    {
        // bin/ лежит в Program Files: у обычного пользователя прав на создание
        // может не быть. Падать из-за этого на старте нельзя — про нехватку
        // прав скажет тот код, который реально туда пишет (скачивание ядра),
        // и скажет понятнее. Так же поступает Swift-версия (try?).
        foreach (var dir in new[] { BinDir, DataDir, LogDir })
        {
            try
            {
                Directory.CreateDirectory(dir);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
    }
}
