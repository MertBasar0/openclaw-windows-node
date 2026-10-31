[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$UpdateManifest,
    [Parameter(Mandatory)][string]$DotnetDumpPath,
    [ValidateRange(10,300)][int]$ToolTimeoutSeconds = 90
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node') { throw 'Inspection requires the authorized disposable hosted Windows job.' }
$root = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
$run = [IO.Path]::GetFullPath($RunDirectory)
if ($root -notmatch '^C:\\OC1676[A-Za-z0-9_-]*$' -or -not $run.StartsWith($root + '\evidence\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Inspection paths must belong to this task.' }
$tool = (Resolve-Path -LiteralPath $DotnetDumpPath).Path
if (-not $tool.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Use the task-local inspector.' }
$private = Join-Path $root ('private-inspection-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $private | Out-Null
$receiptPath = Join-Path $run 'hook-absence.json'
$inventoryPath = Join-Path $run 'managed-assembly-names.json'
if ((Test-Path $receiptPath) -or (Test-Path $inventoryPath)) { throw 'Preserve the existing inspection; do not overwrite it.' }
$receipt = [ordered]@{Result='BLOCKED';Reason='INSPECTION_NOT_COMPLETE';InspectedUtc=$null;ProcessId=$null;StartedUtc=$null;Tool='dotnet-dump 10.0.750501';CompleteInventory=$false;RawDumpPublished=$false;RawPrivateFilesRemoved=$false}
function Invoke-Inspector([string[]]$Arguments,[string]$Label) {
    $info = [Diagnostics.ProcessStartInfo]::new($tool)
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $p = [Diagnostics.Process]::Start($info)
    $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
    try {
        if (-not $p.WaitForExit($ToolTimeoutSeconds * 1000)) { $p.Kill($true); $p.WaitForExit(); throw 'INSPECTOR_TIMEOUT' }
        $outText = $stdout.GetAwaiter().GetResult(); $errText = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $private ($Label + '.stdout.txt')),$outText)
        [IO.File]::WriteAllText((Join-Path $private ($Label + '.stderr.txt')),$errText)
        if ($p.ExitCode -ne 0) { throw 'INSPECTOR_NONZERO_EXIT' }
        return $outText + "`n" + $errText
    } finally { $p.Dispose() }
}
function Assert-SameProcess {
    $p = Get-Process -Id ([int]$transition.NewPid) -ErrorAction Stop
    if ($p.StartTime.ToUniversalTime().ToString('o') -cne $transition.NewStartedUtc -or $p.Path -ine $expectedExe) { throw 'RESTART_PROCESS_IDENTITY_CHANGED' }
    return $p
}
try {
    $transitionPath = Join-Path $run 'transition.json'
    $bindingPath = Join-Path $run 'startup-regression\native-binding.json'
    $transition = Get-Content $transitionPath -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    $binding = Get-Content $bindingPath -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    $manifest = Get-Content $UpdateManifest -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    $hook = Get-Content (Join-Path $root 'driver-hook\hook-receipt.json') -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    $expectedExe = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenClawTray\OpenClaw.Tray.WinUI.exe'
    if ($binding.ProcessId -ne $transition.NewPid -or $binding.StartedUtc -cne $transition.NewStartedUtc -or -not $binding.FreshStartupMarker -or $binding.ExpectedVersion -cne '2026.9.8-2') { throw 'FRESH_B_STARTUP_NOT_PROVEN' }
    if ((Get-FileHash $UpdateManifest).Hash -ine $transition.UpdateManifestSha256 -or $binding.PayloadSha256 -ine $manifest.PayloadSha256 -or $transition.PayloadSha256 -ine $manifest.PayloadSha256) { throw 'B_PAYLOAD_BINDING_MISMATCH' }
    if ((Get-FileHash $expectedExe).Hash -ine $binding.ExecutableSha256 -or (Get-FileHash (Join-Path $root 'driver-hook\Issue1676.StartupHook.dll')).Hash -ine $hook.HookSha256) { throw 'B_OR_HOOK_FILE_CHANGED' }
    $null = Assert-SameProcess
    $receipt.ProcessId = $transition.NewPid; $receipt.StartedUtc = $transition.NewStartedUtc
    $receipt.PayloadSha256 = $manifest.PayloadSha256; $receipt.HookSha256 = $hook.HookSha256
    $receipt.ToolSha256 = (Get-FileHash $tool).Hash
    $version = Invoke-Inspector -Arguments @('--version') -Label 'version'
    if ($version.Trim() -notmatch '^10\.0\.750501(?:\+|\s|$)') { throw 'INSPECTOR_VERSION_MISMATCH' }
    $dump = Join-Path $private 'restarted-test-only.dmp'
    $null = Assert-SameProcess
    $null = Invoke-Inspector -Arguments @('collect','--process-id',[string]$transition.NewPid,'--type','Full','--output',$dump) -Label 'collect'
    if (-not (Test-Path $dump) -or (Get-Item $dump).Length -eq 0) { throw 'DUMP_NOT_CREATED' }
    $null = Assert-SameProcess
    # dumpdomain is DAC-backed managed assembly/module enumeration, not the OS module list.
    $domain = Invoke-Inspector -Arguments @('analyze',$dump,'-c','dumpdomain','-c','exit') -Label 'dumpdomain'
    $runtime = Invoke-Inspector -Arguments @('analyze',$dump,'-c','eeversion','-c','exit') -Label 'eeversion'
    $null = Assert-SameProcess
    $parserDiagnostics = [ordered]@{}
    $receipt.ParserDiagnostics = $parserDiagnostics
    . "$PSScriptRoot\Parse-SosInventory.ps1"
    $inventory = Get-SosManagedInventory -Text $domain -Diagnostics $parserDiagnostics
    if ($runtime -match '(?i)\b(?:error|failed|unable|unsupported|interrupted|aborted)\b|could not|not supported|out of memory') { throw 'SOS_RUNTIME_IDENTIFICATION_FAILED' }
    if ($runtime -notmatch '\b10\.0\.') { throw 'EXPECTED_DOTNET10_RUNTIME_NOT_IDENTIFIED' }
    $clean = $inventory.Assemblies
    $hookSeen = $inventory.HookPresent
    $receipt.CompleteInventory = $true; $receipt.AssemblyCount = $inventory.AssemblyCount; $receipt.ModuleCount = $inventory.ModuleCount; $receipt.UnnamedDynamicAssemblyCount = $inventory.UnnamedDynamicAssemblyCount
    $receipt.InspectedUtc = [DateTime]::UtcNow.ToString('o'); $receipt.HookPresent = $hookSeen
    $receipt.Result = if ($hookSeen) { 'FAIL' } else { 'PASS' }
    $receipt.Reason = if ($hookSeen) { 'HOOK_PRESENT_AFTER_RESTART' } else { 'COMPLETE_MANAGED_INVENTORY_WITHOUT_HOOK_AT_OBSERVED_BOUNDARY' }
    $clean | ConvertTo-Json -Depth 8 | Set-Content $inventoryPath -Encoding utf8
    if ($hookSeen) { throw 'HOOK_PRESENT_AFTER_RESTART' }
} catch {
    if ($receipt.Result -ne 'FAIL') { $receipt.Result='BLOCKED'; $receipt.Reason=if ($_.Exception.Message -cmatch '^[A-Z0-9_]+$') { $_.Exception.Message } else { 'INSPECTOR_OPERATION_FAILED' } }
    throw
} finally {
    # The private directory is uniquely created here, outside every upload path.
    Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction Continue
    $receipt.RawPrivateFilesRemoved = -not (Test-Path -LiteralPath $private)
    if (-not $receipt.RawPrivateFilesRemoved) { $receipt.Result='BLOCKED'; $receipt.Reason='PRIVATE_INSPECTION_CLEANUP_FAILED' }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content $receiptPath -Encoding utf8
    if (-not $receipt.RawPrivateFilesRemoved) { throw 'PRIVATE_INSPECTION_CLEANUP_FAILED' }
}
