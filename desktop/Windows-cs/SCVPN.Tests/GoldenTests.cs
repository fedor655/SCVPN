using System.Text.Json;
using System.Text.Json.Nodes;
using SCVPN.Core;
using Xunit;

namespace SCVPN.Tests;

/// <summary>
/// Сверка с поведением двух уже работающих реализаций — прежней на Python и
/// core-swift. Покрываются ровно те места, где ошибка тихая: сервер
/// разберётся «почти правильно» и не подключится, а выглядеть это будет как
/// проблема сети.
///
/// Откуда какой эталон взят — в Golden/README.md. Там же три случая, где C#
/// намеренно расходится с Python: это исправленные ошибки Python, а не регресс.
/// </summary>
public class GoldenTests
{
    // ------------------------------------------------------------------
    // Разбор ссылок
    // ------------------------------------------------------------------
    public static IEnumerable<object[]> LinkCases() => TestData.CaseNames("links_swift.json");

    [Theory]
    [MemberData(nameof(LinkCases))]
    public void Link_parses_exactly_as_the_reference(string name)
    {
        var row = TestData.Case("links_swift.json", name);
        var link = row["link"]!.GetValue<string>();
        var server = LinkParser.ParseLink(link);

        if (row["server"] is null)
        {
            Assert.Null(server);
            return;
        }

        Assert.NotNull(server);
        Assert.Equal(
            TestData.Canonical(row["server"]),
            TestData.Canonical(TestData.ToNode(server)));
        Assert.Equal(row["key"]!.GetValue<string>(), server!.Key());
        Assert.Equal(
            TestData.Canonical(row["outbound"]),
            TestData.Canonical(server.ToOutbound("proxy")));
    }

    public static IEnumerable<object[]> SubscriptionCases() =>
        TestData.CaseNames("subscription_texts_swift.json");

    [Theory]
    [MemberData(nameof(SubscriptionCases))]
    public void Subscription_text_parses_exactly_as_the_reference(string name)
    {
        var row = TestData.Case("subscription_texts_swift.json", name);
        var servers = LinkParser.ParseSubscriptionText(row["text"]!.GetValue<string>());

        Assert.Equal(
            TestData.Canonical(row["servers"]),
            TestData.Canonical(TestData.ToNode(servers)));
    }

    // ------------------------------------------------------------------
    // Конфиги ядер
    // ------------------------------------------------------------------
    public static IEnumerable<object[]> XrayCases() => TestData.CaseNames("xray_configs.json");

    [Theory]
    [MemberData(nameof(XrayCases))]
    public void Xray_config_matches_the_reference(string name)
    {
        var row = TestData.Case("xray_configs.json", name);
        var server = JsonSerializer.Deserialize<Server>(row["server"]!.ToJsonString())!;

        var config = XrayConfigBuilder.Build(
            server,
            row["socks_port"]!.GetValue<int>(),
            row["http_port"]!.GetValue<int>(),
            row["route_mode"]!.GetValue<string>(),
            row["block_ads"]!.GetValue<bool>(),
            null,
            row["log_level"]!.GetValue<string>());

        Assert.Equal(TestData.Canonical(row["config"]), TestData.Canonical(config));
    }

    public static IEnumerable<object[]> SingboxCases() => TestData.CaseNames("singbox_configs.json");

    [Theory]
    [MemberData(nameof(SingboxCases))]
    public void Singbox_config_matches_the_reference(string name)
    {
        var row = TestData.Case("singbox_configs.json", name);

        // В эталоне на месте пути до ядра стоит метка: путь зависит от машины.
        var config = SingboxConfigBuilder.Build(
            row["socks_port"]!.GetValue<int>(),
            TestData.Strings(row["exclude_ips"]),
            "<XRAY_EXE>",
            row["log_level"]!.GetValue<string>(),
            row["split_mode"]!.GetValue<string>(),
            TestData.Strings(row["split_apps"]));

        Assert.Equal(TestData.Canonical(row["config"]), TestData.Canonical(config));
    }

    [Fact]
    public void Singbox_always_routes_xray_itself_around_the_tunnel()
    {
        // Без этого правила режим «Авто» в TUN зацикливался: Xray решает пустить
        // сайт напрямую, его прямое соединение снова попадает в TUN, оттуда
        // обратно в Xray. Правило обязано быть первым — sing-box берёт первое
        // совпавшее.
        var config = SingboxConfigBuilder.Build(10808, new List<string>(), @"C:\app\bin\xray.exe");
        var first = config["route"]!["rules"]!.AsArray()[0]!;

        Assert.Equal(@"C:\app\bin\xray.exe", first["process_path"]!.AsArray()[0]!.GetValue<string>());
        Assert.Equal("direct", first["outbound"]!.GetValue<string>());
    }

    // ------------------------------------------------------------------
    // Сведения о подписке и подписи
    // ------------------------------------------------------------------
    public static IEnumerable<object[]> InfoCases() => TestData.CaseNames("subscription_info.json");

    [Theory]
    [MemberData(nameof(InfoCases))]
    public void Subscription_info_matches_the_reference(string name)
    {
        var row = TestData.Case("subscription_info.json", name);
        var headers = new Dictionary<string, string>();
        foreach (var pair in row["headers"]!.AsObject())
        {
            headers[pair.Key] = pair.Value!.GetValue<string>();
        }

        var info = SubscriptionInfo.FromHeaders(headers);
        info.Fetched = string.Empty;   // время снятия эталона в сравнении не участвует

        Assert.Equal(TestData.Canonical(row["info"]), TestData.Canonical(TestData.ToNode(info)));
        Assert.Equal(row["used"]!.GetValue<long>(), info.Used);
        Assert.Equal(row["unlimited"]!.GetValue<bool>(), info.Unlimited);
        Assert.Equal(row["used_ratio"]!.GetValue<double>(), info.UsedRatio, 6);
        Assert.Equal(row["device_limit_reached"]!.GetValue<bool>(), info.DeviceLimitReached);
    }

    [Fact]
    public void Human_labels_match_the_reference()
    {
        var labels = TestData.Load("labels.json");

        foreach (var row in labels["human_bytes"]!.AsArray())
        {
            var value = row!["value"]!.GetValue<long>();
            Assert.Equal(row["text"]!.GetValue<string>(), SubscriptionInfo.HumanBytes(value));
        }

        foreach (var row in labels["human_interval"]!.AsArray())
        {
            var hours = row!["hours"]!.GetValue<int>();
            Assert.Equal(row["text"]!.GetValue<string>(), SubscriptionInfo.HumanInterval(hours));
        }
    }

    [Fact]
    public void Human_bytes_uses_a_dot_regardless_of_the_system_locale()
    {
        // На русской локали форматирование по умолчанию даёт запятую, и подпись
        // разъехалась бы со всеми остальными платформами.
        var previous = Thread.CurrentThread.CurrentCulture;
        try
        {
            Thread.CurrentThread.CurrentCulture = new System.Globalization.CultureInfo("ru-RU");
            Assert.Contains(".", SubscriptionInfo.HumanBytes(1610612736));
        }
        finally
        {
            Thread.CurrentThread.CurrentCulture = previous;
        }
    }

    // ------------------------------------------------------------------
    // HWID
    // ------------------------------------------------------------------
    [Fact]
    public void Hwid_matches_the_reference_to_the_character()
    {
        // Изменение этого значения занимает у каждого пользователя новый слот в
        // лимите устройств панели. Именно поэтому оно проверяется эталоном, а не
        // «выглядит правильным».
        var golden = TestData.Load("hwid.json");
        Assert.Equal(Native.Hwid.Salt, golden["salt"]!.GetValue<string>());

        foreach (var row in golden["cases"]!.AsArray())
        {
            var source = row!["source"]!.GetValue<string>();
            Assert.Equal(row["hwid"]!.GetValue<string>(), Native.Hwid.Compute(source));
        }
    }

    // ------------------------------------------------------------------
    // Хранилище
    // ------------------------------------------------------------------
    [Fact]
    public void Profiles_survive_a_read_write_round_trip()
    {
        var text = TestData.LoadText("profiles.json");
        var profiles = Store.ParseProfiles(text);

        Assert.Equal(
            TestData.Canonical(JsonNode.Parse(text)),
            TestData.Canonical(JsonNode.Parse(Store.SerializeProfiles(profiles))));
        Assert.Equal(3, profiles.AllServers().Count);
    }

    [Fact]
    public void Settings_keep_keys_this_version_does_not_know_about()
    {
        // hwid когда-то был именно таким ключом. Потерять неизвестное — значит
        // однажды потерять привязку устройства у всех.
        var text = TestData.LoadText("settings.json");
        var settings = Store.ParseSettings(text);

        Assert.Equal("deadbeef-1234-5678-9abc-def012345678", settings.Hwid);
        Assert.Equal(
            TestData.Canonical(JsonNode.Parse(text)),
            TestData.Canonical(JsonNode.Parse(Store.SerializeSettings(settings))));
        Assert.Contains("unknown_future_key", Store.SerializeSettings(settings));
    }

    [Fact]
    public void Broken_files_give_defaults_instead_of_a_crash()
    {
        var profiles = Store.ParseProfiles("это не json");
        Assert.Empty(profiles.AllServers());

        var settings = Store.ParseSettings("{ сломано");
        Assert.Equal(10808, settings.SocksPort);
        Assert.Equal("proxy", settings.VpnMode);
    }
}
