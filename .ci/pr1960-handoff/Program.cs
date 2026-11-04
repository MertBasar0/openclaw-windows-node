using System.Diagnostics;
using System.Reflection;
using System.Reflection.PortableExecutable;
using System.Runtime.Loader;
using System.Text.Json;

var payload = Path.GetFullPath(args[0]);
var version = args[1];
var target = args[2];
var receipt = args[3];
var targetAsset = args[4];

void Require(bool value, string message)
{
    if (!value) throw new InvalidOperationException(message);
}

AssemblyLoadContext.Default.Resolving += (context, requested) =>
{
    var path = Path.Combine(payload, requested.Name + ".dll");
    return File.Exists(path) ? context.LoadFromAssemblyPath(path) : null;
};
var app = AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(payload, "OpenClaw.Tray.WinUI.dll"));
var shared = AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(payload, "OpenClaw.Shared.dll"));
var owner = shared.GetType("OpenClaw.Shared.AppVersionInfo", throwOnError: true)!;
var current = (string)owner.GetProperty("Version")!.GetValue(null)!;
var displayed = (string)owner.GetProperty("DisplayVersion")!.GetValue(null)!;
var projection = app.GetType("OpenClawTray.Presentation.SettingsAppInfoProjection", true)!;
var settings = (string)projection.GetMethod("ResolveDisplayVersion")!.Invoke(null, [displayed, null])!;
Require(current == version && settings == "v" + version, $"Unexpected packaged runtime/Settings version: {current} / {settings}.");
var numeric = app.GetName().Version;
Require(numeric == Assembly.GetExecutingAssembly().GetName().Version && numeric == new Version(2026, 10, 5, 0), $"Unexpected Updatum numeric baseline: {numeric}.");
var productVersion = FileVersionInfo.GetVersionInfo(app.Location).ProductVersion;
Require(productVersion?.Split('+')[0] == version, $"Unexpected WinUI product version: {productVersion}.");
Require(!(bool)app.GetType("OpenClawTray.AppIdentity", true)!.GetProperty("IsDev")!.GetValue(null)!, "The packaged app has a development identity.");
Require(File.ReadAllText(Path.Combine(payload, "app-identity.txt")).Trim() == "release", "Missing Release identity marker.");
using (var stream = File.OpenRead(Path.Combine(payload, "OpenClaw.Tray.WinUI.exe")))
using (var image = new PEReader(stream))
    Require(image.PEHeaders.CoffHeader.Machine == Machine.Amd64, "Expected a Windows x64 apphost.");

var ordering = shared.GetType("OpenClaw.Shared.OpenClawReleaseVersion", true)!;
object Parse(string value)
{
    object?[] arguments = [value, null];
    Require((bool)ordering.GetMethod("TryParse")!.Invoke(null, arguments)!, $"Production parser rejected {value}.");
    return arguments[1]!;
}
Require((int)ordering.GetMethod("CompareTo")!.Invoke(Parse(target), [Parse(current)])! > 0,
    $"The live target {target} must be newer than {current}.");

Environment.SetEnvironmentVariable("OPENCLAW_UPDATE_CHANNEL", "alpha");
var backend = Activator.CreateInstance(app.GetType("OpenClawTray.Services.UpdatumUpdateBackend", true)!, nonPublic: true)!;
var pipeline = app.GetType("OpenClawTray.Services.UpdateCheckPipeline", true)!;
var check = (Task)pipeline.GetMethod("CheckAsync")!.Invoke(null, [backend, current])!;
await check.WaitAsync(TimeSpan.FromMinutes(2));
var outcome = check.GetType().GetProperty("Result")!.GetValue(check)!;
var selected = outcome.GetType().GetProperty("SelectedRelease")!.GetValue(outcome);
var selectedTag = selected?.GetType().GetProperty("TagName")?.GetValue(selected) as string;
Require((bool)outcome.GetType().GetProperty("UpdateFound")!.GetValue(outcome)! && selectedTag == target,
    $"Packaged Updatum discovery selected '{selectedTag}' instead of '{target}'.");

File.WriteAllText(receipt, JsonSerializer.Serialize(new
{
    current, settings, numericAssemblyVersion = numeric!.ToString(), productVersion,
    selectedTag, targetAsset, nativeRuntime = "win-x64", identity = "release",
    productCommit = Environment.GetEnvironmentVariable("SOURCE_SHA"),
    controllerCommit = Environment.GetEnvironmentVariable("GITHUB_SHA"),
    configuration = "Release", signing = "unsigned fork CI build",
    probe = "Extracted production code plus live release discovery on Windows x64; no download or installation invoked."
}, new JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine($"{settings} -> {selectedTag} via extracted Updatum backend; compatible released asset {targetAsset}.");
