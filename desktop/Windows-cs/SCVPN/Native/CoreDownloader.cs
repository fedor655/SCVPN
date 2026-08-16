using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SCVPN.Native;

/// <summary>Сколько скачано и сколько всего — для полоски загрузки.</summary>
/// <remarks>
/// <see cref="Total"/> равен нулю, если сервер не прислал Content-Length:
/// полоска в этом случае обязана быть неопределённой, а не «0 %».
/// </remarks>
public readonly struct DownloadProgress
{
    public DownloadProgress(long got, long total)
    {
        Got = got;
        Total = total;
    }

    public long Got { get; }

    public long Total { get; }
}

/// <summary>
/// Разовое скачивание ядра Xray-core и компонентов TUN (sing-box + wintun)
/// с официальных источников.
/// </summary>
/// <remarks>
/// Берём последний релиз из репозиториев XTLS/Xray-core и SagerNet/sing-box,
/// скачиваем архив под архитектуру системы и распаковываем в <c>bin/</c> ровно
/// нужные файлы. Это единственные «внешние» источники, и они официальные
/// и открытые.
///
/// Архитектуру спрашиваем у <see cref="Arch.Host"/>, а не у процесса: на
/// Windows on ARM приложение работает под эмуляцией x64, но ядра — отдельные
/// процессы, и им положены нативные arm64-бинарники (см.
/// docs/windows-arm64-plan.md). Особенно это важно для wintun: x64-DLL
/// в arm64-процессе sing-box не загрузится вовсе, а ошибка была бы
/// невнятной — «не найден wintun».
/// </remarks>
public static class CoreDownloader
{
    public const string ReleasesApi = "https://api.github.com/repos/XTLS/Xray-core/releases/latest";
    public const string SingboxReleasesApi = "https://api.github.com/repos/SagerNet/sing-box/releases/latest";
    public const string WintunUrl = "https://www.wintun.net/builds/wintun-0.14.1.zip";

    /// <summary>Что вынимаем из архива Xray-core.</summary>
    private static readonly string[] Wanted = { "xray.exe", "geoip.dat", "geosite.dat" };

    /// <summary>
    /// GitHub отвечает 403 на запросы без User-Agent — это его требование
    /// к API. HttpClient, в отличие от requests, сам ничего не подставляет.
    /// </summary>
    private const string UserAgent = "SCVPN";

    private const int ChunkSize = 64 * 1024;

    private static readonly TimeSpan ApiTimeout = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Таймаут на скачивание архива.
    /// </summary>
    /// <remarks>
    /// В Python <c>timeout=120</c> ограничивал ожидание одного куска, а
    /// <see cref="HttpClient.Timeout"/> ограничивает операцию целиком, включая
    /// чтение тела. Оставить те же две минуты значило бы рвать вполне рабочую
    /// загрузку сорокамегабайтного архива на медленном канале, поэтому запас
    /// щедрый: он ловит только намертво зависшее соединение, а отмену по
    /// желанию пользователя делает CancellationToken.
    /// </remarks>
    private static readonly TimeSpan DownloadTimeout = TimeSpan.FromMinutes(10);

    // Три таблицы выбора держим рядом: при появлении условного
    // windows-arm64-v9 правка должна быть одна.

    /// <summary>Имя ассета Xray-core под архитектуру.</summary>
    /// <remarks>
    /// Всё, что не arm64, считаем x64: приложение собирается только под
    /// win-x64 и win-arm64, на 32-битной Windows оно попросту не запустится.
    /// </remarks>
    public static string XrayAssetFor(string arch) =>
        arch == "arm64" ? "Xray-windows-arm64-v8a.zip" : "Xray-windows-64.zip";

    /// <summary>Окончание имени архива sing-box под архитектуру.</summary>
    public static string SingboxSuffixFor(string arch) =>
        arch == "arm64" ? "windows-arm64.zip" : "windows-amd64.zip";

    /// <summary>Путь нужной DLL внутри архива с wintun.net.</summary>
    public static string WintunMemberFor(string arch) =>
        arch == "arm64" ? "arm64/wintun.dll" : "amd64/wintun.dll";

    /// <summary>
    /// Начало имени ассета Xray-core — запасной способ его найти.
    /// </summary>
    /// <remarks>
    /// Суффикс версии архитектуры (<c>-v8a</c>) в истории проекта уже менялся.
    /// Падать из-за переименования, когда нужный архив в релизе лежит, не
    /// стоит: точное совпадение — первым, префикс — вторым.
    /// </remarks>
    private static string XrayPrefixFor(string arch) =>
        arch == "arm64" ? "Xray-windows-arm64" : "Xray-windows-64";

    /// <summary>Скачать и распаковать ядро Xray-core. Вернуть версию.</summary>
    /// <remarks>
    /// <paramref name="bytes"/> — отдельным каналом, а не строкой в
    /// <paramref name="log"/>: раньше каждый кусок в 64 КБ уезжал в лог
    /// отдельной строкой, и на пятнадцатимегабайтном архиве это две с лишним
    /// сотни строк «Скачано X / Y КБ», в которых тонет всё остальное.
    ///
    /// Все ожидания идут с ConfigureAwait(false), поэтому распаковка (а она
    /// синхронная и небыстрая) выполняется в пуле потоков, а не на потоке
    /// интерфейса, даже если метод вызван из обработчика кнопки.
    /// </remarks>
    public static async Task<string> DownloadCoreAsync(
        IProgress<string>? log,
        IProgress<DownloadProgress>? bytes,
        CancellationToken ct = default)
    {
        var arch = Arch.Host;
        Paths.EnsureDirs();

        log?.Report("Узнаю последнюю версию Xray-core…");
        var release = await LatestReleaseAsync(ReleasesApi, "Xray-core", ct).ConfigureAwait(false);
        var url = PickXrayAsset(release.Tag, release.Assets, arch);
        log?.Report($"Версия {release.Tag}. Скачиваю {XrayAssetFor(arch)}…");

        using var archive = await DownloadAsync(url, bytes, ct).ConfigureAwait(false);

        log?.Report("Распаковываю…");
        using (var zip = new ZipArchive(archive, ZipArchiveMode.Read))
        {
            foreach (var entry in zip.Entries)
            {
                // Внутри архива файлы лежат в подпапке — берём только имя.
                var name = MatchWanted(entry.Name);
                if (name is null)
                {
                    continue;
                }

                ExtractTo(entry, Path.Combine(Paths.BinDir, name));
                log?.Report($"  -> bin/{name}");
            }
        }

        var missing = Wanted.Where(w => !File.Exists(Path.Combine(Paths.BinDir, w))).ToList();
        if (missing.Count > 0)
        {
            throw new InvalidOperationException(
                $"После распаковки не хватает файлов: {string.Join(", ", missing)}");
        }

        // Метку ставим только после проверки: она не должна пережить неудачную
        // распаковку, иначе CorePresent() соврёт про готовое ядро.
        StampBin(arch, log, Paths.XrayExe);

        log?.Report($"Готово. Ядро Xray-core {release.Tag} установлено в bin/");
        return release.Tag;
    }

    /// <summary>
    /// Скачать компоненты TUN. Вернуть версию sing-box.
    /// </summary>
    /// <remarks>
    /// На Windows компоненты TUN — это sing-box плюс wintun: sing-box поднимает
    /// туннель, а wintun даёт ему виртуальный адаптер. В отличие от macOS,
    /// где sing-box качает и кладёт к себе привилегированный демон, здесь оба
    /// файла лежат рядом с приложением.
    /// </remarks>
    public static async Task<string> DownloadTunAsync(
        IProgress<string>? log,
        IProgress<DownloadProgress>? bytes,
        CancellationToken ct = default)
    {
        var arch = Arch.Host;
        Paths.EnsureDirs();

        log?.Report("Узнаю последнюю версию sing-box…");
        var release = await LatestReleaseAsync(SingboxReleasesApi, "sing-box", ct).ConfigureAwait(false);
        var url = PickSingboxAsset(release.Tag, release.Assets, arch);
        log?.Report($"Версия sing-box {release.Tag}. Скачиваю…");

        using var archive = await DownloadAsync(url, bytes, ct).ConfigureAwait(false);

        // Лежащий в bin/ wintun.dll годится только тогда, когда метка уже наша.
        // После установки arm64-сборки поверх x64 файл на месте, но чужой, и
        // одного File.Exists хватило бы, чтобы оставить его навсегда: sing-box
        // такую DLL не загрузит вовсе, а пожалуется невнятно — «не найден
        // wintun». Считаем до распаковки: ниже метка меняется.
        var wintunOk = File.Exists(Paths.WintunDll) && BinArch() == arch;

        log?.Report("Распаковываю sing-box.exe…");
        var found = false;
        using (var zip = new ZipArchive(archive, ZipArchiveMode.Read))
        {
            foreach (var entry in zip.Entries)
            {
                if (string.Equals(entry.Name, "sing-box.exe", StringComparison.OrdinalIgnoreCase))
                {
                    ExtractTo(entry, Paths.SingboxExe);
                    found = true;
                }
                else if (string.Equals(entry.Name, "wintun.dll", StringComparison.OrdinalIgnoreCase))
                {
                    // Вдруг лежит в архиве. Архив выбран под нашу архитектуру,
                    // так что и DLL из него будет нужной.
                    ExtractTo(entry, Paths.WintunDll);
                    wintunOk = true;
                }
            }
        }

        if (!found)
        {
            throw new InvalidOperationException("sing-box.exe не найден в архиве");
        }

        if (!wintunOk)
        {
            await DownloadWintunAsync(log, arch, ct).ConfigureAwait(false);
        }

        StampBin(arch, log, Paths.SingboxExe, Paths.WintunDll);

        log?.Report($"Готово. sing-box {release.Tag} установлен.");
        return release.Tag;
    }

    /// <summary>Скачать официальный wintun.dll (драйвер TUN-адаптера).</summary>
    private static async Task DownloadWintunAsync(IProgress<string>? log, string arch, CancellationToken ct)
    {
        log?.Report("Скачиваю wintun.dll (wintun.net)…");
        var member = WintunMemberFor(arch);

        // Полоску байтов сюда не отдаём: файл меньше сотни килобайт, и её
        // рывок с полного состояния обратно в ноль выглядел бы сбоем.
        using var archive = await DownloadAsync(WintunUrl, null, ct).ConfigureAwait(false);
        using var zip = new ZipArchive(archive, ZipArchiveMode.Read);
        foreach (var entry in zip.Entries)
        {
            // Внутри архива нужен bin/<арх>/wintun.dll — сравниваем по хвосту
            // пути целиком, потому что имена файлов во всех папках одинаковые.
            if (!entry.FullName.EndsWith(member, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            ExtractTo(entry, Paths.WintunDll);
            log?.Report("  -> bin/wintun.dll");
            return;
        }

        throw new InvalidOperationException(
            $"wintun.dll не найден в архиве wintun.net (нужен {member})");
    }

    /// <summary>Ядро Xray на месте и подходит системе.</summary>
    /// <remarks>
    /// Сверка архитектуры здесь, а не отдельной проверкой в интерфейсе:
    /// пользователь, обновившийся на ARM-машине, остаётся со старыми
    /// x64-ядрами, и без сверки получил бы невнятную ошибку запуска. С ней
    /// UI сам предложит скачать ядро — тем же путём, каким предлагает при
    /// первом запуске. Ничего удалять не нужно, скачивание перезапишет файлы.
    /// </remarks>
    public static bool CorePresent() =>
        BinArch() == Arch.Host
        && File.Exists(Paths.XrayExe)
        && File.Exists(Paths.GeoipDat)
        && File.Exists(Paths.GeositeDat);

    /// <summary>Компоненты TUN на месте и подходят системе.</summary>
    /// <remarks>
    /// Спрашиваем и про wintun, в отличие от macOS-версии, где хватает одного
    /// sing-box: на Windows без DLL туннель не поднимется, а её отсутствие
    /// проявилось бы уже в логе sing-box.
    /// </remarks>
    public static bool TunPresent() =>
        BinArch() == Arch.Host
        && File.Exists(Paths.SingboxExe)
        && File.Exists(Paths.WintunDll);

    /// <summary>Удалить компоненты TUN. <c>true</c> — было что удалять.</summary>
    /// <remarks>
    /// Проверять, поднят ли туннель, здесь не нужно так, как на macOS: там
    /// удаляет root-овый демон и обязан отказать живому туннелю, а тут файлы
    /// лежат рядом с приложением, и sing-box держит их открытыми — Windows не
    /// даст удалить занятый exe и сама бросит исключение. Вызывающая сторона
    /// всё равно отключается первой.
    /// </remarks>
    public static bool RemoveTun(IProgress<string>? log)
    {
        var removed = false;
        foreach (var file in new[] { Paths.SingboxExe, Paths.WintunDll })
        {
            if (!File.Exists(file))
            {
                continue;
            }

            File.Delete(file);
            log?.Report($"  удалён {Path.GetFileName(file)}");
            removed = true;
        }

        log?.Report(removed ? "Компоненты TUN удалены." : "Компоненты TUN и так не установлены.");
        return removed;
    }

    /// <summary>Под какую архитектуру скачан текущий <c>bin/</c>.</summary>
    /// <remarks>
    /// Метки нет — значит bin/ достался от сборки, которая умела только x64.
    /// </remarks>
    public static string BinArch()
    {
        try
        {
            var stamp = File.ReadAllText(Paths.ArchStamp).Trim();
            return stamp.Length > 0 ? stamp : "x64";
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "x64";
        }
    }

    /// <summary>
    /// Пометить <c>bin/</c> архитектурой скачанного и убрать оттуда бинарники
    /// чужой архитектуры, кроме перечисленных в <paramref name="keep"/>.
    /// </summary>
    /// <remarks>
    /// Метка одна на всю папку, и записанная она ручается за всё, что рядом.
    /// А рядом вполне может лежать чужое: установщик arm64-версии специально
    /// не чистит <c>bin/</c> (иначе ядро перекачивалось бы при каждом
    /// обновлении, см. docs/windows-arm64-plan.md), а ядро и компоненты TUN
    /// качаются по отдельности и порядок ничем не навязан — пункты меню «⋯»
    /// доступны оба всегда. Без уборки хватало одного «Скачать ядро Xray» на
    /// ARM-машине, чтобы новая метка поручилась за оставшийся x64-шный
    /// sing-box, и TunPresent() уже не позвал бы скачать нужный.
    ///
    /// Убираем только при смене метки и только то, что этой загрузкой не
    /// перезаписано. Гео-базы не трогаем: они одинаковы для всех архитектур и
    /// всё равно перезапишутся вместе с ядром.
    ///
    /// Занятый файл (ядро прямо сейчас запущено) пропускаем: ронять из-за
    /// этого уже удавшуюся загрузку хуже, чем оставить лишний файл.
    /// Саму запись метки не глушим: если писать в bin/ нельзя, распаковка выше
    /// уже упала бы, и молчаливая потеря метки только запутала бы следующий
    /// запуск.
    /// </remarks>
    private static void StampBin(string arch, IProgress<string>? log, params string[] keep)
    {
        if (BinArch() != arch)
        {
            foreach (var file in new[] { Paths.XrayExe, Paths.SingboxExe, Paths.WintunDll })
            {
                if (Array.IndexOf(keep, file) >= 0 || !File.Exists(file))
                {
                    continue;
                }

                try
                {
                    File.Delete(file);
                    log?.Report($"  убран {Path.GetFileName(file)} от прошлой архитектуры");
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }
            }
        }

        File.WriteAllText(Paths.ArchStamp, arch);
    }

    /// <summary>Тег и список ассетов последнего релиза.</summary>
    private static async Task<(string Tag, List<(string Name, string Url)> Assets)> LatestReleaseAsync(
        string api, string what, CancellationToken ct)
    {
        using var http = NewClient(ApiTimeout);
        using var request = new HttpRequestMessage(HttpMethod.Get, api);
        request.Headers.Add("Accept", "application/vnd.github+json");

        using var response = await http.SendAsync(request, ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"GitHub не отдал сведения о релизе {what}");
        }

        var json = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        var tag = root.TryGetProperty("tag_name", out var tagNode) && tagNode.ValueKind == JsonValueKind.String
            ? tagNode.GetString() ?? "?"
            : "?";

        var assets = new List<(string Name, string Url)>();
        if (root.TryGetProperty("assets", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var asset in list.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
                var url = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
                if (!string.IsNullOrEmpty(name) && !string.IsNullOrEmpty(url))
                {
                    assets.Add((name!, url!));
                }
            }
        }

        return (tag, assets);
    }

    private static string PickXrayAsset(string tag, List<(string Name, string Url)> assets, string arch)
    {
        var exact = XrayAssetFor(arch);
        foreach (var asset in assets)
        {
            if (asset.Name == exact)
            {
                return asset.Url;
            }
        }

        // Запасной поиск по началу имени. Хвост «.zip» обязателен: рядом
        // с архивом в релизе лежит одноимённый .dgst с контрольными суммами,
        // и по одному префиксу мы скачали бы его.
        var prefix = XrayPrefixFor(arch);
        foreach (var asset in assets)
        {
            if (asset.Name.StartsWith(prefix, StringComparison.Ordinal)
                && asset.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                return asset.Url;
            }
        }

        throw new InvalidOperationException($"В релизе {tag} не найден ассет {exact}");
    }

    private static string PickSingboxAsset(string tag, List<(string Name, string Url)> assets, string arch)
    {
        var suffix = SingboxSuffixFor(arch);
        foreach (var asset in assets)
        {
            // legacy-сборка — для старых Windows, её собственный exe нам не
            // подходит. Для arm64 такого варианта не существует вовсе, но
            // проверка не мешает.
            if (asset.Name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
                && !asset.Name.Contains("legacy", StringComparison.OrdinalIgnoreCase))
            {
                return asset.Url;
            }
        }

        throw new InvalidOperationException($"В релизе sing-box {tag} не найден архив {suffix}");
    }

    /// <summary>Скачать архив целиком в память.</summary>
    /// <remarks>
    /// ResponseHeadersRead, а не полное чтение: иначе HttpClient сам сложил бы
    /// весь ответ в буфер, и полоска загрузки прыгнула бы с нуля сразу
    /// в готово. В память, а не во временный файл, — архивы измеряются
    /// десятками мегабайт, и распаковывать из памяти проще, чем убирать за
    /// собой файл при каждой ошибке.
    /// </remarks>
    private static async Task<MemoryStream> DownloadAsync(
        string url, IProgress<DownloadProgress>? bytes, CancellationToken ct)
    {
        using var http = NewClient(DownloadTimeout);
        using var response = await http
            .GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct)
            .ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Не удалось скачать архив: сервер ответил {(int)response.StatusCode}");
        }

        var total = response.Content.Headers.ContentLength ?? 0;
        var buffer = new MemoryStream(total > 0 && total < int.MaxValue ? (int)total : 1 << 20);
        using (var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
        {
            var chunk = new byte[ChunkSize];
            long got = 0;
            int read;
            while ((read = await stream.ReadAsync(chunk.AsMemory(0, chunk.Length), ct).ConfigureAwait(false)) > 0)
            {
                buffer.Write(chunk, 0, read);
                got += read;
                bytes?.Report(new DownloadProgress(got, total));
            }
        }

        buffer.Position = 0;
        return buffer;
    }

    private static HttpClient NewClient(TimeSpan timeout)
    {
        var http = new HttpClient { Timeout = timeout };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        return http;
    }

    /// <summary>Имя файла из архива, приведённое к нашему написанию.</summary>
    /// <remarks>
    /// Сравнение без учёта регистра, но на диск кладём каноническое имя:
    /// пути в <see cref="Paths"/> написаны строчными, и «Xray.exe» из архива
    /// сломал бы их на любой файловой системе, где регистр важен (тесты
    /// гоняются и не на Windows).
    /// </remarks>
    private static string? MatchWanted(string baseName)
    {
        foreach (var wanted in Wanted)
        {
            if (string.Equals(baseName, wanted, StringComparison.OrdinalIgnoreCase))
            {
                return wanted;
            }
        }

        return null;
    }

    private static void ExtractTo(ZipArchiveEntry entry, string destination)
    {
        using var source = entry.Open();
        using var target = File.Create(destination);
        source.CopyTo(target);
    }
}
