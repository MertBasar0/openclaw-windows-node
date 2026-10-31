// Test artifact only. Never add this hook or its environment variable to product code.
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Octokit;
using Updatum;

public static class StartupHook
{
    public static void Initialize()
    {
        string configPath = Environment.GetEnvironmentVariable("OC1676_DRIVER_CONFIG") ?? "";
        // The vendor's restarted application must be a normal, uninstrumented process.
        Environment.SetEnvironmentVariable("DOTNET_STARTUP_HOOKS", null);
        Environment.SetEnvironmentVariable("OC1676_DRIVER_CONFIG", null);
        if (string.IsNullOrWhiteSpace(configPath)) return;
        _ = Task.Run(() => Run(configPath));
    }

    private static void Run(string configPath)
    {
        DriverConfig config = null;
        try
        {
            if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Native Windows required.");
            config = JsonSerializer.Deserialize<DriverConfig>(File.ReadAllText(configPath))
                ?? throw new InvalidDataException("Missing driver configuration.");
            Validate(config);
            AssemblyLoadContext.Default.Resolving += (_, name) =>
            {
                if (name.Name != "Updatum" && name.Name != "Octokit") return null;
                return AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(Path.GetDirectoryName(config.ExePath), name.Name + ".dll"));
            };
            // Load the target application's exact dependencies, not copies beside the hook.
            foreach (string name in new[] { "Octokit", "Updatum" })
                AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(Path.GetDirectoryName(config.ExePath), name + ".dll"));
            Write(config, "hook-ready.json", new { ProcessId = Environment.ProcessId, ExePath = Environment.ProcessPath,
                PayloadSha256 = config.PayloadSha256, HookSha256 = Hash(typeof(StartupHook).Assembly.Location) });
            string gate = Path.Combine(config.RunDirectory, "install.gate.json");
            var deadline = Stopwatch.StartNew();
            while (!File.Exists(gate))
            {
                if (deadline.Elapsed > TimeSpan.FromSeconds(config.DeadlineSeconds))
                    throw new TimeoutException("No install gate after observed native startup.");
                Thread.Sleep(200); // Observation cadence only; the parent supplies readiness, not a sleep.
            }
            var request = JsonSerializer.Deserialize<InstallGate>(File.ReadAllText(gate));
            if (request == null || request.ProcessId != Environment.ProcessId ||
                !string.Equals(request.PayloadSha256, config.PayloadSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Install gate does not bind this process and payload.");
            Validate(config); // Recheck target, payload and same-image process ownership immediately before effect.
            Install(config).GetAwaiter().GetResult();
        }
        catch (Exception error)
        {
            // Driver failure is not startup success or product failure. It cannot fabricate metadata.
            if (config != null && Directory.Exists(config.RunDirectory))
                Write(config, "driver-failed.json", new { Error = error.GetType().FullName, error.Message });
        }
    }

    private static void Validate(DriverConfig c)
    {
        string canonical = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenClawTray", "OpenClaw.Tray.WinUI.exe");
        if (!string.Equals(Path.GetFullPath(c.ExePath), canonical, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Environment.ProcessPath, canonical, StringComparison.OrdinalIgnoreCase) ||
            Assembly.GetEntryAssembly()?.GetName().Name != "OpenClaw.Tray.WinUI")
            throw new InvalidOperationException("Hook is not inside the canonical installed Companion process.");
        uint size = 0;
        if (GetCurrentPackageFullName(ref size, IntPtr.Zero) != 15700)
            throw new InvalidOperationException("Packaged execution is not this proof lane.");
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("OPENCLAW_TRAY_DATA_DIR")))
            throw new InvalidOperationException("Data-isolated startup cannot prove installed integration.");
        if (c.DeadlineSeconds < 1 || c.DeadlineSeconds > 1800) throw new InvalidDataException("Invalid deadline.");
        string root = Path.GetFullPath(c.WorkRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (string p in new[] { c.RunDirectory, c.PayloadZip })
            if (!Path.GetFullPath(p).StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Driver paths must be task-owned.");
        foreach (string p in new[] { c.ExePath, c.PayloadZip, c.RunDirectory }) RejectReparse(p);
        string directory = Path.GetDirectoryName(c.ExePath);
        RequireHash(c.ExePath, c.BeforeExeSha256);
        RequireHash(Path.Combine(directory, "OpenClaw.Tray.WinUI.dll"), c.BeforeDllSha256);
        RequireHash(Path.Combine(directory, "Updatum.dll"), c.UpdatumSha256);
        RequireHash(Path.Combine(directory, "Octokit.dll"), c.OctokitSha256);
        RequireHash(c.PayloadZip, c.PayloadSha256);
        // The vendor uses taskkill /IM, not a PID-only shutdown. A dedicated VM is mandatory.
        var sameName = Process.GetProcessesByName("OpenClaw.Tray.WinUI");
        try
        {
            if (sameName.Length != 1 || sameName[0].Id != Environment.ProcessId)
                throw new InvalidOperationException("Another Companion image exists; vendor image-name shutdown is unsafe.");
        }
        finally { foreach (var p in sameName) p.Dispose(); }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static async Task Install(DriverConfig c)
    {
        if (typeof(UpdatumManager).Assembly.GetName().Version != new Version(1, 3, 4, 0))
            throw new InvalidOperationException("Unexpected Updatum API version.");
        if (!string.Equals(EntryApplication.ExecutablePath, c.ExePath, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.GetFullPath(EntryApplication.BaseDirectory).TrimEnd('\\'), Path.GetDirectoryName(c.ExePath).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Updatum resolved a different target.");
        // These are controlled input descriptors, not published releases. No discovery/selection/network call occurs.
        var release = new Release("", "", "", "", 0L, "issue1676-local", "v" + c.PayloadVersion,
            c.SourceHead, "Issue 1676 controlled payload", "Unpublished native boundary proof", false, false,
            DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, null, "", "", Array.Empty<ReleaseAsset>());
        var asset = new UpdatumDownloadedAsset(release, new ReleaseAsset(), c.PayloadZip);
        var manager = new UpdatumManager("openclaw", "openclaw-windows-node", null, null)
        {
            FetchOnlyLatestRelease = true,
            InstallUpdateSingleFileExecutableName = "OpenClaw.Tray.WinUI"
        };
        manager.InstallUpdateCompleted += (_, _) =>
        {
            // In 1.3.4 this event precedes cmd.exe launch. Save evidence; NEVER label it completion.
            string script = Path.Combine(Path.GetTempPath(), Path.GetFileNameWithoutExtension(c.PayloadZip) + "-UpdatumAutoUpgrade.bat");
            string saved = Path.Combine(c.RunDirectory, "vendor-generated.bat");
            File.Copy(script, saved, false);
            Write(c, "vendor-script-created.json", new { ProcessId = Environment.ProcessId,
                ScriptSha256 = Hash(saved), Target = EntryApplication.BaseDirectory,
                State = "generated-before-cmd-start-not-install-success" });
        };
        Write(c, "install-invoked.json", new { ProcessId = Environment.ProcessId, c.PayloadSha256,
            UpdatumAssemblySha256 = Hash(typeof(UpdatumManager).Assembly.Location), c.SourceHead });
        // Exact pinned public contract. It owns ZIP extraction, generated replacement script, shutdown and restart.
        bool initiated = await manager.InstallUpdateAsync(asset, forceTerminate: true, runArguments: null);
        if (!initiated) throw new InvalidOperationException("Vendor did not initiate replacement.");
        // The Windows ZIP success path exits this process, so reaching here is not native success evidence.
        Write(c, "unexpected-return.json", new { initiated });
    }

    private static void RejectReparse(string path)
    {
        for (string p = Path.GetFullPath(path); !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
            if ((File.Exists(p) || Directory.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Reparse path refused.");
    }
    public static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
    private static void RequireHash(string path, string expected)
    {
        if (!string.Equals(Hash(path), expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Artifact changed: " + Path.GetFileName(path));
    }
    private static void Write(DriverConfig c, string name, object value) =>
        File.WriteAllText(Path.Combine(c.RunDirectory, name), JsonSerializer.Serialize(value));
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref uint length, IntPtr name);
}
public sealed class DriverConfig
{
    public string WorkRoot { get; set; }
    public string RunDirectory { get; set; }
    public string ExePath { get; set; }
    public string BeforeExeSha256 { get; set; }
    public string BeforeDllSha256 { get; set; }
    public string PayloadZip { get; set; }
    public string PayloadSha256 { get; set; }
    public string PayloadVersion { get; set; }
    public string SourceHead { get; set; }
    public string UpdatumSha256 { get; set; }
    public string OctokitSha256 { get; set; }
    public int DeadlineSeconds { get; set; }
}
public sealed class InstallGate
{
    public int ProcessId { get; set; }
    public string PayloadSha256 { get; set; }
}
