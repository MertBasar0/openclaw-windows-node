using OpenClaw.TestSupport;

namespace OpenClaw.Tray.Tests;

public sealed class UninstallGatewayCleanupHelperTests
{
    [Fact]
    public async Task LocalGatewayUrl_RecognizesOnlyLoopbackHosts()
    {
        using var temp = new TempDirectory("uninstall-gateway-");

        var stdout = await UninstallScriptHost.RunAsync(temp, ["Test-LocalGatewayUrl"], """
            foreach ($url in @(
                'ws://localhost:18789', 'WS://LOCALHOST:18789', 'ws://127.0.0.1:18789', 'ws://[::1]:18789',
                'wss://gateway.example', 'wss://localhost.example', '', 'not a url'
            )) {
                Write-Output "$url=$(Test-LocalGatewayUrl $url)"
            }
            """);

        Assert.Equal(
            [
                "ws://localhost:18789=True",
                "WS://LOCALHOST:18789=True",
                "ws://127.0.0.1:18789=True",
                "ws://[::1]:18789=True",
                "wss://gateway.example=False",
                "wss://localhost.example=False",
                "=False",
                "not a url=False",
            ],
            ReadLines(stdout));
    }

    [Theory]
    [InlineData("ws://127.0.0.1:19555", false)]
    [InlineData("wss://gateway.example", true)]
    public async Task RegistryCleanup_RemovesLegacyRecord_AndOnlyRemoteRecordsCountAsExternal(
        string remainingUrl, bool expectedExternal)
    {
        using var temp = new TempDirectory("uninstall-gateway-");
        var registry = new JsonObject
        {
            ["activeId"] = "legacy",
            ["gateways"] = new JsonArray(
                new JsonObject
                {
                    ["id"] = "legacy",
                    ["isLocal"] = true,
                    ["friendlyName"] = "Local (OpenClawGateway)",
                    ["url"] = "ws://localhost:18789",
                },
                new JsonObject
                {
                    ["id"] = "remaining",
                    ["isLocal"] = false,
                    ["friendlyName"] = "Other gateway",
                    ["url"] = remainingUrl,
                }),
        };
        File.WriteAllText(temp.Combine("gateways.json"), registry.ToJsonString());
        Directory.CreateDirectory(temp.Combine("gateways", "legacy"));
        Directory.CreateDirectory(temp.Combine("gateways", "remaining"));

        var stdout = await UninstallScriptHost.RunAsync(
            temp,
            [
                "Ensure-AppRoot", "Write-GatewayLog", "Add-CleanupWarning", "Get-JsonPropertyValue",
                "Read-JsonFile", "Write-JsonFileAtomic", "Test-LocalGatewayUrl",
                "Test-SetupManagedLocalRecord", "Test-ExternalGatewayRecord",
                "Remove-SetupManagedGatewayRecords",
            ],
            """
            $DistroName = 'OpenClawGateway'
            $result = Remove-SetupManagedGatewayRecords -DataDir $AppRoot
            Write-Output "$($result.RemainingCount)|$($result.HasExternalGateways)|$($cleanupWarnings.Count)"
            """);

        Assert.Equal([$"1|{expectedExternal}|0"], ReadLines(stdout));
        var saved = JsonNode.Parse(File.ReadAllText(temp.Combine("gateways.json")))!;
        Assert.Null(saved["activeId"]);
        var remaining = Assert.Single(saved["gateways"]!.AsArray());
        Assert.Equal("remaining", remaining!["id"]!.GetValue<string>());
        Assert.False(Directory.Exists(temp.Combine("gateways", "legacy")));
        Assert.True(Directory.Exists(temp.Combine("gateways", "remaining")));
    }

    [Theory]
    [InlineData("~/state", null, "home", "state")]
    [InlineData("~/state", "~/custom", "home", "custom", "state")]
    [InlineData("~", null, "home")]
    public async Task ExecApprovalsPaths_ResolveConfiguredStateDirectoryUnderHome(
        string stateDirectory, string? openClawHome, params string[] expectedStateSegments)
    {
        using var temp = new TempDirectory("uninstall-gateway-");

        var stdout = await UninstallScriptHost.RunAsync(
            temp,
            ["Resolve-UsablePathValue", "Expand-ExecApprovalsHomePath", "Resolve-ExecApprovalsPaths"],
            "Resolve-ExecApprovalsPaths -DataDir $AppRoot",
            new Dictionary<string, string?>
            {
                ["OPENCLAW_STATE_DIR"] = stateDirectory,
                ["OPENCLAW_HOME"] = openClawHome,
                ["HOME"] = temp.Combine("home"),
            });

        Assert.Equal(
            [
                Path.Combine([temp.Path, .. expectedStateSegments, "exec-approvals.json"]),
                temp.Combine("exec-approvals.json"),
            ],
            ReadLines(stdout));
    }

    private static string[] ReadLines(string stdout) =>
        stdout.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries);
}
