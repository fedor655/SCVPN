using System.Diagnostics;
using System.Runtime.InteropServices;

namespace SCVPN.Core;

/// <summary>
/// Job-объект Windows, к которому привязаны все дочерние ядра.
/// </summary>
/// <remarks>
/// Флаг JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE означает: когда закроется последний
/// дескриптор job-объекта, ядро ОС само снимет все процессы в нём. Дескриптор
/// закрывается вместе с процессом приложения — в том числе если приложение
/// сняли из диспетчера задач или оно упало без единой строки кода уборки.
///
/// Это закрывает главный класс аварий проекта: «туннель поднят, а управлять им
/// нечем» — xray/sing-box пережили приложение, трафик идёт через мёртвый
/// прокси, системный прокси не снят. Python-версия боролась с этим
/// pid-файлами и разбором tasklist уже после факта (см. tun.cleanup_stray);
/// здесь проблему решает ядро ОС в момент смерти приложения.
///
/// Уборка по pid-файлам всё равно остаётся — но только ради сирот от
/// Python-версии, оставшихся на диске после обновления.
/// </remarks>
public sealed class ProcessJob : IDisposable
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    private static readonly ProcessJob _shared = new ProcessJob();

    /// <summary>Общий job приложения: все ядра живут в нём.</summary>
    public static ProcessJob Shared => _shared;

    private readonly object _lock = new object();
    private IntPtr _handle;
    private bool _disposed;

    public ProcessJob()
    {
        _handle = Create();
    }

    /// <summary>
    /// Привязать процесс к job-объекту. Вызывать сразу после Process.Start.
    /// </summary>
    /// <remarks>
    /// Молча ничего не делает, если job создать не удалось: это оптимизация
    /// живучести, а не условие работы. На урезанной или старой системе
    /// (или когда процесс уже успел завершиться) приложение обязано
    /// продолжать работать ровно как раньше.
    /// </remarks>
    public void Assign(Process process)
    {
        lock (_lock)
        {
            if (_handle == IntPtr.Zero) return;
            try
            {
                AssignProcessToJobObject(_handle, process.Handle);
            }
            catch (Exception)
            {
                // Process.Handle бросает, если процесс уже отвалился, —
                // привязывать нечего, и это не повод ронять запуск.
            }
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
            if (_handle != IntPtr.Zero)
            {
                // Именно это закрытие и убивает всё, что в job осталось.
                CloseHandle(_handle);
                _handle = IntPtr.Zero;
            }
        }
    }

    private static IntPtr Create()
    {
        try
        {
            IntPtr handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) return IntPtr.Zero;

            var info = default(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            int size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    // Job без флага бесполезен и даже вреден (лишний уровень
                    // вложенности), поэтому не оставляем его.
                    CloseHandle(handle);
                    return IntPtr.Zero;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
            return handle;
        }
        catch (Exception)
        {
            // Нет API — работаем как раньше, без страховки.
            return IntPtr.Zero;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob, int jobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);

    // Раскладка структур заморожена Win32 API: поля и их порядок менять нельзя,
    // размерные поля обязаны быть указательного размера (x64 и arm64 — 8 байт).
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
}
