using System.Globalization;
using SCVPN.Theme;
using Xunit;

namespace SCVPN.Tests;

/// <summary>
/// Палитра дублируется вручную в четырёх местах — здесь, в Android, в
/// core-swift и раньше в ui/theme.py. Расхождение сегодня никем не
/// проверяется: приложение на одной платформе тихо уезжает в другой оттенок,
/// и замечает это только пользователь с двумя устройствами.
///
/// Тест — перевод ThemeTests.swift из core-swift: он ходит за файлом
/// Android-версии в дерево репозитория тем же способом.
/// </summary>
public class PaletteTests
{
    /// <summary>
    /// null — файла нет: проект собрали в отрыве от дерева репозитория
    /// (скопировали одну папку на другую машину). Сверять тогда не с чем, и
    /// падение говорило бы не о том. Сама палитра при этом всё равно
    /// проверяется — тестом на «строго серую».
    /// </summary>
    private static string? AndroidColorsXml()
    {
        var path = Path.Combine(
            TestData.RepoRoot(), "android", "app", "src", "main", "res", "values", "colors.xml");
        return File.Exists(path) ? File.ReadAllText(path) : null;
    }

    [Fact]
    public void Palette_matches_android_colors_xml()
    {
        var xml = AndroidColorsXml();
        if (xml is null) return;
        foreach (var color in Palette.All)
        {
            Assert.True(
                xml.Contains(color, StringComparison.OrdinalIgnoreCase),
                $"палитра разошлась с Android: нет {color}");
        }
    }

    [Fact]
    public void Android_defines_every_colour_we_use_by_name()
    {
        var xml = AndroidColorsXml();
        if (xml is null) return;

        foreach (var (name, value) in Palette.Named)
        {
            Assert.True(
                xml.Contains($"name=\"{name}\">{value}<", StringComparison.OrdinalIgnoreCase),
                $"у Android {name} не равен {value}");
        }
    }

    [Fact]
    public void Palette_is_greyscale_only()
    {
        // Цвета в теме нет вовсе — состояния различаются формой и текстом.
        // Появление цветного значения означает, что кто-то начал показывать
        // состояние оттенком, а это ломает и доступность, и Android заодно.
        foreach (var hex in Palette.All)
        {
            var r = byte.Parse(hex.Substring(1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            var g = byte.Parse(hex.Substring(3, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            var b = byte.Parse(hex.Substring(5, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);

            Assert.True(r == g && g == b, $"{hex} — не оттенок серого");
        }
    }

    [Fact]
    public void Section_heading_stands_exactly_above_the_server_names()
    {
        // Колонка текста — самая заметная вертикаль в списке, и заголовок
        // раздела обязан вставать ровно над именами, а не над краем строки.
        Assert.Equal(
            Metrics.ListPadding + Metrics.RowMarker + Metrics.RowTextLeading,
            Metrics.SectionPadding);
    }
}
