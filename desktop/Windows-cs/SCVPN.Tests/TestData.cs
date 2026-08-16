using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SCVPN.Tests;

/// <summary>
/// Доступ к эталонным файлам и сравнение JSON без оглядки на порядок ключей.
/// </summary>
public static class TestData
{
    /// <summary>
    /// Корень репозитория. Считается от пути этого файла во время компиляции —
    /// как в core-swift, где ThemeTests ходит за colors.xml тем же способом.
    /// Через рабочий каталог теста это не найти: он в bin/Debug/net10.0-windows.
    /// </summary>
    public static string RepoRoot([CallerFilePath] string? thisFile = null)
    {
        // <repo>/desktop/Windows-cs/SCVPN.Tests/TestData.cs
        var dir = Path.GetDirectoryName(thisFile)!;      // SCVPN.Tests
        return Path.GetFullPath(Path.Combine(dir, "..", "..", ".."));
    }

    /// <summary>
    /// Эталоны копируются в выходной каталог (см. csproj) — читаем их оттуда,
    /// чтобы тест работал и там, где исходников рядом нет.
    /// </summary>
    public static string GoldenDir => Path.Combine(AppContext.BaseDirectory, "Golden");

    public static JsonNode Load(string file)
    {
        var path = Path.Combine(GoldenDir, file);
        return JsonNode.Parse(File.ReadAllText(path))
               ?? throw new InvalidOperationException($"Пустой эталон: {path}");
    }

    public static string LoadText(string file) => File.ReadAllText(Path.Combine(GoldenDir, file));

    /// <summary>Случай эталона по имени — для [Theory] с именами случаев.</summary>
    public static JsonObject Case(string file, string name)
    {
        foreach (var row in Load(file).AsArray())
        {
            if (row is JsonObject obj && obj["name"]?.GetValue<string>() == name)
            {
                return obj;
            }
        }

        throw new InvalidOperationException($"В {file} нет случая {name}");
    }

    public static IEnumerable<object[]> CaseNames(string file)
    {
        foreach (var row in Load(file).AsArray())
        {
            yield return new object[] { row!["name"]!.GetValue<string>() };
        }
    }

    /// <summary>
    /// Канонический вид JSON: ключи объектов отсортированы. Порядок ключей у
    /// System.Text.Json и у Python разный, и посимвольное сравнение утонуло бы
    /// в ложных отказах.
    /// </summary>
    public static string Canonical(JsonNode? node)
    {
        if (node is null)
        {
            return "null";
        }

        if (node is JsonObject obj)
        {
            var parts = obj
                .OrderBy(kv => kv.Key, StringComparer.Ordinal)
                .Select(kv => JsonSerializer.Serialize(kv.Key) + ":" + Canonical(kv.Value));
            return "{" + string.Join(",", parts) + "}";
        }

        if (node is JsonArray arr)
        {
            return "[" + string.Join(",", arr.Select(Canonical)) + "]";
        }

        return node.ToJsonString();
    }

    public static JsonNode? ToNode(object? value)
    {
        return value is null ? null : JsonSerializer.SerializeToNode(value, value.GetType());
    }

    public static List<string> Strings(JsonNode? array)
    {
        var result = new List<string>();
        if (array is JsonArray arr)
        {
            foreach (var item in arr)
            {
                result.Add(item!.GetValue<string>());
            }
        }

        return result;
    }
}
