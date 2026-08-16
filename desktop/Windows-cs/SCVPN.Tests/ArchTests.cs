using SCVPN.Native;
using Xunit;

namespace SCVPN.Tests;

/// <summary>
/// Выбор бинарников по архитектуре — единственное место с ветвлением, где
/// ошибка тихая: скачается не тот файл, а упадёт всё уже в другом модуле.
/// Особенно коварна ошибка в wintun: DLL чужой архитектуры не загрузится в
/// sing-box вовсе, а сообщение было бы про «не найден wintun».
/// </summary>
public class ArchTests
{
    [Theory]
    [InlineData("x64", "Xray-windows-64.zip")]
    [InlineData("arm64", "Xray-windows-arm64-v8a.zip")]
    public void Xray_asset_is_chosen_by_architecture(string arch, string expected)
    {
        Assert.Equal(expected, CoreDownloader.XrayAssetFor(arch));
    }

    [Theory]
    [InlineData("x64", "windows-amd64.zip")]
    [InlineData("arm64", "windows-arm64.zip")]
    public void Singbox_asset_is_chosen_by_architecture(string arch, string expected)
    {
        Assert.Equal(expected, CoreDownloader.SingboxSuffixFor(arch));
    }

    [Theory]
    [InlineData("x64", "amd64/wintun.dll")]
    [InlineData("arm64", "arm64/wintun.dll")]
    public void Wintun_member_is_chosen_by_architecture(string arch, string expected)
    {
        Assert.Equal(expected, CoreDownloader.WintunMemberFor(arch));
    }

    [Fact]
    public void Host_architecture_is_one_of_the_three_we_know()
    {
        Assert.Contains(Arch.Host, new[] { "x64", "arm64", "x86" });
    }

    [Fact]
    public void Emulation_is_only_possible_on_arm64()
    {
        // На x64-системе эмулировать нечего. Если это утверждение когда-нибудь
        // сломается, значит определение архитектуры перепутало ОС и процесс —
        // ровно та ошибка, из-за которой на ARM скачивались x64-ядра.
        if (Arch.Emulated)
        {
            Assert.Equal("arm64", Arch.Host);
        }
    }

    [Fact]
    public void Executable_name_is_normalised_for_split_tunnel_rules()
    {
        // sing-box сравнивает с process_name, где расширение есть, а
        // Process.GetProcesses() отдаёт имя без него.
        Assert.Equal("Telegram.exe", RunningApps.Normalize("Telegram"));
        Assert.Equal("Telegram.exe", RunningApps.Normalize("  Telegram.exe  "));
        // Регистр не трогаем: Python его тоже не трогал, а сравнение имён у
        // sing-box регистронезависимо — переписывать введённое незачем.
        Assert.Equal("chrome.EXE", RunningApps.Normalize("chrome.EXE"));
        Assert.Equal(string.Empty, RunningApps.Normalize("   "));
    }
}
