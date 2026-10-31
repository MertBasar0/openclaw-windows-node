# #1676 restarted-process managed inventory

This is a test-only inspector, not product code and not a runtime-policy change. It is intended solely for the authorized disposable GitHub-hosted Windows job. No product or tool executable was run on the developer host while preparing it.

## Tool pin and preparation

- Microsoft `dotnet-dump` **10.0.750501**, NuGet publication 2026-10-07.
- Package URL: https://api.nuget.org/v3-flatcontainer/dotnet-dump/10.0.750501/dotnet-dump.10.0.750501.nupkg
- Package SHA-256: `ae70c9f37548e1e006467893e21ae41a005fefaf2270e29642b415df053324a7`.
- NuGet repository commit: `ad724c4b85e7ae775e42f393c6e95a7557a57954` in `dotnet/diagnostics`.
- `Install-Inspector.ps1 -ToolsRoot C:\OC1676Actions\inspector-tools` verifies that package, installs it using a fresh local-only NuGet feed and a task-local tool directory, then verifies the CLI version. It does not install globally or alter PATH, certificates, Defender, execution policy, diagnostics flags, or product runtimeconfig.
- The tool package targets .NET 8.0; an installed compatible tool runtime is necessary. The self-contained Companion payload is .NET 10.0.13. Tool collection/analysis of this exact target remains a native execution result, not a preparation claim.

The pinned Companion B runtimeconfig has `System.Diagnostics.Debugger.IsSupported=false`; this is not evidence that the diagnostics protocol is disabled. Leave it unchanged. If collection is denied or unsupported, retain BLOCKED.

## Invocation

After the exact controlled update has produced `transition.json` and `startup-regression/native-binding.json`:

```powershell
& .\Test-HookAbsence.ps1 `
  -WorkRoot C:\OC1676Actions `
  -RunDirectory $exactControlledUpdateRun `
  -UpdateManifest C:\OC1676Actions\artifacts\base-b\payload-manifest.json `
  -DotnetDumpPath C:\OC1676Actions\inspector-tools\bin\dotnet-dump.exe
```

The native-binding file must prove B's fresh startup and verified payload before this inspector runs. It is written before the final metadata assertion, so a genuine `PRODUCT_REGRESSION_METADATA_STALE` failure does not prevent independent hook-absence inspection. A setup/startup failure does.

The script rechecks the PID/start-time/executable tuple before and after collection and after analysis, and binds the input manifest, payload and hook hashes. It collects a **Full** dump, then executes SOS `dumpdomain` and `eeversion` on that immutable dump. It never enumerates other processes, kills the Companion, or changes the runtime.

## What makes enumeration sufficient

The maintained SOS implementation at the exact NuGet source commit was inspected:

- [`DumpDomain` in strike.cpp](https://github.com/dotnet/diagnostics/blob/ad724c4b85e7ae775e42f393c6e95a7557a57954/src/SOS/Strike/strike.cpp) retrieves and iterates the DAC domain list.
- [`DomainInfo` and `AssemblyInfo` in util.cpp](https://github.com/dotnet/diagnostics/blob/ad724c4b85e7ae775e42f393c6e95a7557a57954/src/SOS/Strike/util.cpp) enumerate each domain's DAC `AssemblyCount` entries, then each assembly's DAC `ModuleCount` entries. Failed assembly/name/module reads produce errors or incomplete rows.

The parser requires the single CoreCLR Domain1, resolves **every** printed Assembly entry into a nonempty named assembly with a Module table and resolved module rows, rejects diagnostic errors/unknown/incomplete rows, requires both `OpenClaw.Tray.WinUI.dll` and `System.Private.CoreLib.dll`, and identifies the .NET10 runtime. Only then is absence of `Issue1676.StartupHook` checked. The pinned startup hook is a non-dynamic managed assembly loaded into the default context; domain-wide enumeration covers it. Recognized dynamic modules are retained as dynamic entries; unknown non-dynamic names cannot pass.

This uses source-backed enumeration semantics plus exact native output, not merely an exit-zero or no-match grep. An unexpected output shape, timeout, partial dump, unavailable DAC/SOS, process exit/reuse or runtime error yields BLOCKED. A detected hook yields FAIL. PASS covers the observed post-startup boundary only, not arbitrary process history. Native proof has not been run during preparation.

## Privacy and cleanup

Full dumps and raw tool output are created only in a unique `C:\OC1676Actions\private-inspection-*` directory, **outside all upload directories**. `finally` removes that owned directory and records whether removal succeeded. Failed cleanup changes the receipt to BLOCKED. The orchestration workflow must upload only selected evidence files, never the WorkRoot or a wildcard containing private inspection paths.

Public outputs are `hook-absence.json` (PID/start-time, hashes, counts, result) and `managed-assembly-names.json` (base names only, no dump addresses or full file paths). Raw dump/tool output must never be uploaded, even on failure. The disposable runner is destroyed after evidence collection.

## Preparation checks

- Both PowerShell scripts passed native PowerShell syntax parsing; their bodies were not executed.
- Confirmed PowerShell's default `ConvertFrom-Json` reads ISO timestamps as `System.DateTime`; `-DateKind String` preserves exact receipt strings. Inspector receipt reads explicitly use the latter. The caller should make the same scoped compatibility change in copied native kit scripts, preserving the pinned originals.
- Package integrity, nuspec/source identity and exact SOS source paths were inspected.
- No additional fake application/probe was added. Exact B's fresh startup plus full managed inventory is the required observation boundary; source review and parsing do not claim the native tool can execute successfully.

References: [Microsoft dotnet-dump documentation](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-dump), [NuGet package](https://www.nuget.org/packages/dotnet-dump/10.0.750501).
