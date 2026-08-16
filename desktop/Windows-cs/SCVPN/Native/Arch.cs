using System.Runtime.InteropServices;

namespace SCVPN.Native;

/// <summary>
/// Архитектура системы — от неё зависит, какие бинарники ядер скачивать.
/// </summary>
/// <remarks>
/// Спрашиваем именно систему, а не себя: на Windows on ARM приложение может
/// работать под эмуляцией x64, и про процесс честный ответ — «x64», хотя ядру
/// нужен arm64-бинарник. Ошибка здесь самая коварная у wintun.dll: x64-DLL в
/// arm64-процессе sing-box не загрузится вовсе, а выглядело бы это как «не
/// найден wintun».
///
/// В ARM-плане (шаг 1) для этого расписан вызов <c>IsWow64Process2</c> через
/// ctypes — в .NET он не нужен: <see cref="RuntimeInformation.OSArchitecture"/>
/// начиная с .NET 6 сам ходит в <c>IsWow64Process2</c> и возвращает
/// архитектуру ОС, а не процесса. Ту, что у процесса, отдельно даёт
/// <see cref="RuntimeInformation.ProcessArchitecture"/> — на их расхождении и
/// держится <see cref="Emulated"/>.
/// </remarks>
public static class Arch
{
    /// <summary>Архитектура ОС: <c>"arm64"</c> | <c>"x64"</c> | <c>"x86"</c>.</summary>
    public static string Host { get; } = Name(RuntimeInformation.OSArchitecture);

    /// <summary>Работаем ли под эмуляцией (x64-сборка на arm64-системе).</summary>
    public static bool Emulated { get; } =
        RuntimeInformation.OSArchitecture == Architecture.Arm64
        && RuntimeInformation.ProcessArchitecture != Architecture.Arm64;

    /// <summary>Строка для стартовых строк лога.</summary>
    /// <remarks>
    /// Мелочь, экономящая часы поддержки: по логу сразу видно, что человек на
    /// ARM-машине, и почему ядро могло скачаться «не то».
    /// </remarks>
    public static string Describe()
    {
        if (!Emulated)
        {
            return $"Windows {Host}";
        }

        return $"Windows {Host}, приложение {Name(RuntimeInformation.ProcessArchitecture)} (эмуляция)";
    }

    private static string Name(Architecture a) => a switch
    {
        Architecture.Arm64 => "arm64",
        Architecture.X86 => "x86",
        // Всё прочее (в том числе arm32) считаем x64 — так же поступал Python.
        // Ключи только "x64" и "arm64" знают словари ассетов в CoreDownloader,
        // и незнакомое значение обрушило бы там выбор файла; arm32-Windows мы
        // не поддерживаем осознанно (раздел 7 ARM-плана).
        _ => "x64",
    };
}
