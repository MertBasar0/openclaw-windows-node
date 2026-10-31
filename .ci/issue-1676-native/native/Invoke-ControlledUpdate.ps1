[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][string]$InstalledManifest,[Parameter(Mandatory)][string]$UpdateManifest,[Parameter(Mandatory)][string]$ExpectedVersion,[ValidateRange(1,1800)][int]$TimeoutSeconds=180)
. "$PSScriptRoot\Native.Common.ps1"
$WorkRoot=Assert-Target $WorkRoot
if(@(Get-Process -Name 'OpenClaw.Tray.WinUI' -ErrorAction SilentlyContinue).Count){throw 'Exit only the task-owned app via its UI. No image-name kill is performed by this runner.'}
if($env:DOTNET_STARTUP_HOOKS){throw 'Existing startup instrumentation present. Use a clean disposable VM shell; do not overwrite it.'}
$installed=Get-Content -LiteralPath $InstalledManifest -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
$candidate=Get-Content -LiteralPath $UpdateManifest -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
if($installed.Kind -cne 'InitialInno' -or $installed.ExpectedVersion -cne '2026.9.8-1' -or $candidate.ExpectedVersion -cne $ExpectedVersion -or $ExpectedVersion -cne '2026.9.8-2' -or $candidate.Kind -notin @('BaselineZip','PatchedZip') -or $candidate.SourceHead -cne $BaseSha -or $installed.SourceHead -cne $BaseSha){throw 'INPUT_MISMATCH: use pinned source A Inno and explicitly expected source B ZIP.'}
Assert-PayloadInstalled $installed
$before=Get-InstalledSnapshot
foreach($view in @('Registry64','Registry32')) {
 if($before.Registry.$view.DisplayVersion.Value -cne '2026.9.8-1' -or $before.Registry.$view.DisplayName.Value -cne 'OpenClaw Companion version 2026.9.8-1'){throw 'FIXTURE_INVALID: restore the real A Inno snapshot; never rewrite the registry to fake the fixture.'}
}
$contract=Get-Content "$PSScriptRoot\..\dependency-contract.json" -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
$hook=Join-Path $WorkRoot 'driver-hook\Issue1676.StartupHook.dll'
$receipt=Get-Content "$WorkRoot\driver-hook\hook-receipt.json" -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
if((Get-FileHash $hook).Hash -ine $receipt.HookSha256 -or (Get-FileHash "$PSScriptRoot\StartupHook.cs").Hash -ine $receipt.SourceSha256){throw 'Hook source/binary receipt mismatch.'}
if($receipt.ProjectSha256 -ine (Get-FileHash "$PSScriptRoot\Issue1676.StartupHook.csproj").Hash -or $receipt.DependencyContractSha256 -ine (Get-FileHash "$PSScriptRoot\..\dependency-contract.json").Hash -or $receipt.TargetFramework -cne 'net10.0' -or $receipt.Configuration -cne 'Release'){throw 'Hook build input receipt mismatch.'}
$exe=Get-InstalledExe;$directory=Split-Path -Parent $exe
foreach($assembly in $contract.Assemblies){if((Get-FileHash (Join-Path $directory ($assembly.Name+'.dll'))).Hash -ine $assembly.Sha256){throw 'Installed dependency differs from inspected exact NuGet assembly. Stop; do not substitute a vendor version.'}}
$zip=Join-Path (Split-Path -Parent $UpdateManifest) $candidate.PayloadFile
if((Get-FileHash $zip).Hash -ine $candidate.PayloadSha256){throw 'Controlled payload changed.'}
$run=Join-Path "$WorkRoot\evidence" ('controlled-update-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run,"$run\temp"|Out-Null
$before|ConvertTo-Json -Depth 12|Set-Content "$run\before.json" -Encoding UTF8
# Updatum deletes its downloaded input. Retain the original hashed payload and consume a task-owned copy.
Copy-Item -LiteralPath $zip -Destination "$run\consumable.zip"
$updatumHash=($contract.Assemblies|Where-Object Name -eq 'Updatum').Sha256
$octokitHash=($contract.Assemblies|Where-Object Name -eq 'Octokit').Sha256
@{WorkRoot=$WorkRoot;RunDirectory=$run;ExePath=$exe;BeforeExeSha256=$before.Files.'OpenClaw.Tray.WinUI.exe';BeforeDllSha256=$before.Files.'OpenClaw.Tray.WinUI.dll';PayloadZip="$run\consumable.zip";PayloadSha256=$candidate.PayloadSha256;PayloadVersion=$ExpectedVersion;SourceHead=$candidate.SourceHead;UpdatumSha256=$updatumHash;OctokitSha256=$octokitHash;DeadlineSeconds=$TimeoutSeconds}|ConvertTo-Json|Set-Content "$run\driver-config.json" -Encoding UTF8
$info=New-NativeProcessInfo $exe
$info.EnvironmentVariables['DOTNET_STARTUP_HOOKS']=$hook
$info.EnvironmentVariables['OC1676_DRIVER_CONFIG']="$run\driver-config.json"
$info.EnvironmentVariables['TEMP']="$run\temp";$info.EnvironmentVariables['TMP']="$run\temp"
$offset=Get-NativeLogPosition
$old=[Diagnostics.Process]::Start($info)
$oldStarted=$old.StartTime.ToUniversalTime().ToString('o')
$timer=[Diagnostics.Stopwatch]::StartNew()
while(-not(Test-Path "$run\hook-ready.json")) {
 if(Test-Path "$run\driver-failed.json"){throw (Get-Content "$run\driver-failed.json" -Raw -Encoding UTF8)}
 if($old.HasExited -or $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw "HOOK_UNAVAILABLE: no startup-hook ready receipt. Evidence: $run. Do not substitute an external-process updater or bypass runtime policy."}
 Start-Sleep -Milliseconds 200
}
$ready=Get-Content "$run\hook-ready.json" -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
if($ready.ProcessId -ne $old.Id -or $ready.PayloadSha256 -ine $candidate.PayloadSha256){throw 'Hook receipt belongs to a different process/payload.'}
[void](Wait-NativeStarted $old.Id $offset $TimeoutSeconds)
# The old process has completed its real startup before the test driver hands over a controlled asset.
$restartOffset=Get-NativeLogPosition
$gateIssuedUtc=[DateTime]::UtcNow.ToString('o')
@{ProcessId=$old.Id;PayloadSha256=$candidate.PayloadSha256}|ConvertTo-Json|Set-Content "$run\install.gate.tmp" -Encoding UTF8
Move-Item -LiteralPath "$run\install.gate.tmp" -Destination "$run\install.gate.json"
$timer.Restart();$new=$null
while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
 if(Test-Path "$run\driver-failed.json"){throw (Get-Content "$run\driver-failed.json" -Raw -Encoding UTF8)}
 if(Test-Path "$run\unexpected-return.json"){throw 'INSTALL_NOT_ESTABLISHED: vendor returned without expected process termination.'}
 $all=@(Get-Process -Name 'OpenClaw.Tray.WinUI' -ErrorAction SilentlyContinue)
 if($all.Count -gt 1){throw 'OWNERSHIP_CONFLICT: multiple processes after install gate. Preserve evidence.'}
 if($all.Count -eq 1 -and $all[0].Path -ieq $exe -and ($all[0].Id -ne $old.Id -or $all[0].StartTime.ToUniversalTime().ToString('o') -ne $oldStarted)){$new=$all[0];break}
 Start-Sleep -Milliseconds 200
}
if(-not $new){throw "INSTALL_NOT_ESTABLISHED: no restarted installed process. Evidence: $run"}
if(-not(Test-Path "$run\vendor-script-created.json")){throw 'INSTALL_NOT_ESTABLISHED: missing exact vendor-script receipt.'}
@{BeforeSnapshotSha256=(Get-FileHash "$run\before.json").Hash;RestartLogOffset=$restartOffset;GateIssuedUtc=$gateIssuedUtc;OldPid=$old.Id;OldStartedUtc=$oldStarted;NewPid=$new.Id;NewStartedUtc=$new.StartTime.ToUniversalTime().ToString('o');UpdateManifestSha256=(Get-FileHash $UpdateManifest).Hash;SourceManifestSha256=$candidate.SourceManifestSha256;PayloadSha256=$candidate.PayloadSha256;Boundary='controlled downloaded asset -> pinned in-process vendor install -> uninstrumented production startup';SelectionAndDownloadExercised=$false}|ConvertTo-Json|Set-Content "$run\transition.json" -Encoding UTF8
# This executable regression checks actual startup, all installed payload hashes and independently expected metadata.
$regressionDirectory=Join-Path $run 'startup-regression'
try {
 & "$PSScriptRoot\Test-StartupRegistration.ps1" -WorkRoot $WorkRoot -PayloadManifest $UpdateManifest -ExpectedVersion $ExpectedVersion -Mode Regression -RestartReceipt "$run\transition.json" -EvidenceDirectory $regressionDirectory -TimeoutSeconds $TimeoutSeconds
 @{Result='PASS';EvidenceDirectory=$regressionDirectory}|ConvertTo-Json|Set-Content "$run\startup-result.json" -Encoding UTF8
} catch {
 @{Result='FAIL';EvidenceDirectory=$regressionDirectory;Error=$_.Exception.Message}|ConvertTo-Json|Set-Content "$run\startup-result.json" -Encoding UTF8
 throw
}

