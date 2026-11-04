using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using System.Text.Json;
using OpenClaw.TestSupport;
using OpenClawTray.Services;
using Updatum;

namespace OpenClaw.Tray.Tests;

[CollectionDefinition("Issue1642 real HTTP", DisableParallelization = true)]
public sealed class Issue1642RealHttpCollection { }

// Runs only in the dedicated disposable Windows job. No fake backend/selector.
// Native UpdateCoordinator/UI and successful installation are NOT exercised.
[Collection("Issue1642 real HTTP")]
public sealed class ProductionUpdaterIntegrationTests
{
    private readonly string _directory;
    private readonly string _caseId = Guid.NewGuid().ToString("N");
    private const string Api = "https://api.github.com";

    public ProductionUpdaterIntegrationTests()
    {
        if (!OperatingSystem.IsWindows() || RuntimeInformation.ProcessArchitecture != Architecture.X64 ||
            Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" ||
            Environment.GetEnvironmentVariable("OPENCLAW_UPDATER_PROOF_FIREWALL") != "1")
            throw new InvalidOperationException("Only the isolated Windows CI proof runner may run this fixture.");
        _directory = Environment.GetEnvironmentVariable("OPENCLAW_UPDATER_PROOF_DIR")
            ?? throw new InvalidOperationException("Missing proof directory.");
        var proxy = new Uri(Environment.GetEnvironmentVariable("HTTPS_PROXY")
            ?? throw new InvalidOperationException("Missing loopback proxy."));
        var guardedPrograms = JsonSerializer.Deserialize<string[]>(
            Environment.GetEnvironmentVariable("OPENCLAW_UPDATER_PROOF_PROGRAMS")
                ?? throw new InvalidOperationException("Missing guarded process list."))
            ?? throw new InvalidOperationException("Invalid guarded process list.");
        Assert.Contains(Environment.ProcessPath ?? "", guardedPrograms, StringComparer.OrdinalIgnoreCase);
        Assert.True(proxy.IsLoopback);
        Assert.False(HttpClient.DefaultProxy.IsBypassed(new Uri(Api)));
        Assert.Equal(proxy, HttpClient.DefaultProxy.GetProxy(new Uri(Api)));
    }

    [Fact]
    public async Task Alpha_UsesRealDiscoveryAndGreatestCompatibleNumericAlpha()
    {
        using var env = new EnvironmentScope("OPENCLAW_UPDATE_CHANNEL", "alpha");
        var b = HostBase();
        var winner = "v" + b + "-alpha.117";
        Configure(b + "-alpha.93", winner, Release("v0.0.0", 1), [
            Release("v" + b + "-alpha.97", 2),
            Release("v" + b + "-alpha.118", 3, "win-arm64"),
            Release("v" + b + "-alpha.10", 4),
            Release(winner, 5)]);
        var backend = new UpdatumUpdateBackend();
        var result = await UpdateCheckPipeline.CheckAsync(backend, b + "-alpha.93");
        Assert.True(result.UpdateFound);
        Assert.Equal(winner, result.SelectedRelease?.TagName);
        Assert.Equal(winner, result.ActivatedFallbackTag);
        Assert.Equal(winner, backend.GetSelectedRelease()?.TagName);
        Assert.Contains("fixture:" + winner, backend.GetChangelog() ?? "");
        AssertKinds("list");
        await AssertSelectedDownloadBlocked(backend, winner);
    }

    [Fact]
    public async Task Alpha_ReplacesActualLowerVendorSelection()
    {
        using var env = new EnvironmentScope("OPENCLAW_UPDATE_CHANNEL", "alpha");
        var b = HostBase();
        var stable = "v" + HostBase(1) + "-1";
        var winner = "v" + HostBase(2) + "-alpha.2";
        Configure(b + "-alpha.93", winner, Release(stable, 1), [Release(stable, 1), Release(winner, 2)]);
        var backend = new UpdatumUpdateBackend();
        // Affirm the actual vendor-selected loser, not a fake supplying it.
        Assert.True(await backend.CheckForUpdatesAsync());
        Assert.Equal(stable, backend.GetSelectedRelease()?.TagName);
        var result = await UpdateCheckPipeline.CheckAsync(backend, b + "-alpha.93");
        Assert.True(result.UpdateFound);
        Assert.Equal(winner, result.SelectedRelease?.TagName);
        Assert.Equal(winner, backend.GetSelectedRelease()?.TagName);
        Assert.Equal(winner, result.ActivatedFallbackTag);
        AssertKinds("list", "list");
        await AssertSelectedDownloadBlocked(backend, winner);
    }

    [Fact]
    public async Task Stable_UsesLatestEndpointAndRetainsVendorFastPath()
    {
        using var env = new EnvironmentScope("OPENCLAW_UPDATE_CHANNEL", "stable");
        var stable = "v" + HostBase(1) + "-1";
        Configure(HostBase(), stable, Release(stable, 1), [Release("v" + HostBase(2) + "-alpha.2", 2)]);
        var backend = new UpdatumUpdateBackend();
        var result = await UpdateCheckPipeline.CheckAsync(backend, HostBase());
        Assert.True(result.UpdateFound);
        Assert.Equal(stable, result.SelectedRelease?.TagName);
        Assert.Null(result.ActivatedFallbackTag);
        Assert.Equal(stable, backend.GetSelectedRelease()?.TagName);
        AssertKinds("latest");
        await AssertSelectedDownloadBlocked(backend, stable);
    }

    [Fact]
    public async Task InstalledAlpha_DoesNotImplicitlyEnableAlphaDiscovery()
    {
        using var env = new EnvironmentScope("OPENCLAW_UPDATE_CHANNEL", null);
        Configure("2026.9.5-alpha.93", null, Release("v0.0.0", 1), [Release("v2026.9.5-alpha.97", 2)]);
        var backend = new UpdatumUpdateBackend();
        var result = await UpdateCheckPipeline.CheckAsync(backend, "2026.9.5-alpha.93");
        Assert.False(result.UpdateFound);
        Assert.Null(result.SelectedRelease);
        Assert.Null(backend.GetSelectedRelease());
        AssertKinds("latest");
    }

    private static string HostBase(int patchIncrement = 0)
    {
        // Read the public default rather than reflect a private vendor field.
        // These are controlled test inputs, NOT a product release/version stamp.
        using var probe = new UpdatumManager("openclaw", "openclaw-windows-node");
        var v = probe.CurrentVersion;
        return $"{v.Major}.{v.Minor}.{checked(Math.Max(0, v.Build) + patchIncrement)}";
    }

    private string AssetName(string tag, string rid = "win-x64") =>
        $"OpenClawTray-proof-{_caseId}-{tag}-{rid}.zip";

    private object Release(string tag, int id, string rid = "win-x64") => new
    {
        id, tag_name = tag, name = tag,
        body = "<!-- openclaw-update: ordinary -->\nfixture:" + tag,
        draft = false, prerelease = tag.Contains("-alpha.", StringComparison.Ordinal),
        created_at = "2026-10-01T00:00:00Z", published_at = "2026-10-01T00:00:00Z",
        url = Api + "/repos/openclaw/openclaw-windows-node/releases/" + id,
        assets = new[] { new {
            id = id * 10, name = AssetName(tag, rid), content_type = "application/zip",
            state = "uploaded", size = 1,
            browser_download_url = Api + "/fixture-assets/" + AssetName(tag, rid),
            url = Api + "/fixture-assets/" + AssetName(tag, rid)
        } }
    };

    private void Configure(string currentVersion, string? expectedTag, object latest, object[] releases, [CallerMemberName] string caseName = "")
    {
        var staging = Path.Combine(_directory, "scenario.next.json");
        var json = JsonSerializer.Serialize(new { caseId = _caseId, caseName, currentVersion, expectedTag, latest, releases });
        File.WriteAllText(Path.Combine(_directory, "case-" + _caseId + ".json"), json);
        File.WriteAllText(staging, json);
        File.Move(staging, Path.Combine(_directory, "scenario.json"), overwrite: true);
    }

    private JsonElement[] Requests() => File.ReadLines(Path.Combine(_directory, "requests.ndjson"))
        .Where(line => !string.IsNullOrWhiteSpace(line))
        .Select(line => { using var d = JsonDocument.Parse(line); return d.RootElement.Clone(); })
        .Where(row => row.TryGetProperty("caseId", out var value) && value.GetString() == _caseId)
        .ToArray();

    private void AssertKinds(params string[] expected) => Assert.Equal(expected,
        Requests().Select(row => row.GetProperty("kind").GetString()).ToArray());

    private async Task AssertSelectedDownloadBlocked(UpdatumUpdateBackend backend, string tag)
    {
        var completed = false;
        await Assert.ThrowsAsync<HttpRequestException>(() =>
            backend.DownloadAndInstallAsync(() => completed = true));
        Assert.False(completed);
        Assert.False(File.Exists(Path.Combine(Path.GetTempPath(), AssetName(tag))));
        var download = Assert.Single(Requests().Where(row => row.GetProperty("kind").GetString() == "blocked-download"));
        Assert.Equal("/fixture-assets/" + AssetName(tag), download.GetProperty("path").GetString());
        Assert.DoesNotContain(Requests(), row => row.GetProperty("kind").GetString() == "forbidden");
    }
}
