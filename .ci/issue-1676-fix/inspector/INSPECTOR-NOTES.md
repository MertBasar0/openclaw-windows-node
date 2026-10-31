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

The parser requires the single CoreCLR Domain1, resolves **every** file-backed Assembly entry into a nonempty named assembly with a Module table and resolved module rows, classifies the exact DAC Reflection.Emit `(Dynamic) []` / `Dynamic Module` form separately, and rejects all other unnamed, inconsistent, diagnostic-error or incomplete rows, requires both `OpenClaw.Tray.WinUI.dll` and `System.Private.CoreLib.dll`, and identifies the .NET10 runtime. Only then is absence of `Issue1676.StartupHook` checked. The pinned startup hook is a non-dynamic managed assembly loaded into the default context; domain-wide enumeration covers it. Recognized reflection-emitted modules are retained as `<reflection-emit>` entries with their observed count; empty names are accepted only with the DAC Dynamic flag and exclusively `Dynamic Module` rows. Unknown non-dynamic names and inconsistent dynamic entries cannot pass. This file-loaded startup hook is not a Reflection.Emit assembly.

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

## Recovery after run 41218421702

That run reached the actual A-to-B update and fresh B startup; inspector collection and analysis reached `UNRESOLVED_ASSEMBLY_ENTRY`. Private raw text was deleted as designed, so its exact rejected row cannot be recovered. Do not state the dynamic case as a proven diagnosis of that particular output until the next observed shape/count establishes it.

A definite source-format bug was nevertheless reproduced in the old parser: it counted three Assembly headers but parsed only two when the third was the legitimate Reflection.Emit form. Named LF and CRLF inputs both passed, so this is not a demonstrated line-ending bug.

Exact supporting source:

- [.NET10.0.13 request.cpp lines2732-2755](https://github.com/dotnet/runtime/blob/v10.0.13/src/coreclr/debug/daccess/request.cpp#L2732-L2755): `GetAssemblyName` returns E_FAIL for Reflection.Emit without a PE path.
- [Pinned SOS util.cpp lines1831-1844](https://github.com/dotnet/diagnostics/blob/ad724c4b85e7ae775e42f393c6e95a7557a57954/src/SOS/Strike/util.cpp#L1831-L1844): the DAC Dynamic marker is printed, then brackets are printed even when name retrieval fails. This produces `(Dynamic) []`.
- [Pinned SOS util.cpp lines1727-1738](https://github.com/dotnet/diagnostics/blob/ad724c4b85e7ae775e42f393c6e95a7557a57954/src/SOS/Strike/util.cpp#L1727-L1738): a reflection module without a filename prints `Dynamic Module`; an unknown ordinary module instead prints `Unknown Module` and still fails our parser.

`Parse-SosInventory.ps1` now owns this strict classification. The absence script calls it and retains bounded `ParserDiagnostics` in its receipt on success or failure: header counts/kinds, unnamed dynamic/non-dynamic counts and module-resolution counts. No raw text, full path, memory address or dump is retained. Successful inventory also records `UnnamedDynamicAssemblyCount` explicitly.

`Test-SosInventoryParser.ps1` uses synthetic strings copied from this source format. It demonstrates the old parser mismatch and passes 12 controls: LF/CRLF, exact Reflection.Emit format, actual hook detection, and rejection of unnamed ordinary entries, inconsistent dynamic entries, malformed headers, missing/truncated/unknown module rows and missing app identity. These are parser controls, not another native update or a substitute for hook-absence proof. The updated three scripts also passed native PowerShell syntax parsing.
