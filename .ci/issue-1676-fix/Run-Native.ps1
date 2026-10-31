[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArtifactRoot,[Parameter(Mandatory)][string]$PatchedArtifactRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node' -or $env:GITHUB_REF -cne 'refs/heads/codex/issue-1676-fix-20261031') {throw 'Only the authorized fresh GitHub-hosted Windows job can execute this lane.'}
if($PSVersionTable.PSVersion -lt [Version]'7.5'){throw 'PowerShell 7.5+ is required for string-preserving receipt reads.'}
. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Desktop.ps1"
$root='C:\OC1676Actions'
if(Test-Path $root){throw 'Refusing to reuse an existing task root.'}
$startUtc=[DateTime]::UtcNow
$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
$installedExe=Get-InstalledExe
foreach($folder in @((Split-Path $installedExe),(Join-Path $env:APPDATA 'OpenClawTray'))) {if(Test-Path $folder){throw 'Existing Companion state; clean runner required.'}}
if(@(Get-Process -Name OpenClaw.Tray.WinUI -ErrorAction SilentlyContinue).Count){throw 'Existing Companion process; refusing execution.'}
foreach($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryHive]::LocalMachine)) {
 foreach($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
  $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$view)
  try {$key=$base.OpenSubKey($RegistrySubkey);if($key){$key.Dispose();throw 'Existing registration; refusing execution.'}}finally{$base.Dispose()}
 }
}
if($env:DOTNET_STARTUP_HOOKS -or $env:OC1676_DRIVER_CONFIG){throw 'Pre-existing instrumentation.'}
if($env:GH_TOKEN -or $env:GITHUB_TOKEN){throw 'Credential-bearing application environment is not accepted.'}
New-Item -ItemType Directory -Path $root,"$root\evidence","$root\public","$root\temp"|Out-Null
$public="$root\public"
@{Root=$root;Computer=$env:COMPUTERNAME;Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Provider='GitHub-hosted';RunId=$env:GITHUB_RUN_ID;RunAttempt=$env:GITHUB_RUN_ATTEMPT;SnapshotAvailable=$false;Isolation='Fresh GitHub-hosted VM; no Windows 11 or snapshot equivalence claimed';CreatedUtc=$startUtc.ToString('o')}|ConvertTo-Json|Set-Content "$root\target.local.json" -Encoding utf8
[void](Assert-Target $root)
Set-NativeEnvironment
$env:TEMP="$root\temp";$env:TMP=$env:TEMP
function Save-Json($Data,[string]$Path){$Data|ConvertTo-Json -Depth 14|Set-Content -LiteralPath $Path -Encoding utf8}
function Stop-OwnedCompanion {
 foreach($process in @(Get-Process -Name OpenClaw.Tray.WinUI -ErrorAction SilentlyContinue)) {
  if($process.Path -ine $installedExe -or $process.SessionId -ne $session -or $process.StartTime.ToUniversalTime() -lt $startUtc){throw 'Unexpected process ownership; not terminating it.'}
  $ownedStart=$process.StartTime.ToUniversalTime()
  $check=Get-Process -Id $process.Id -ErrorAction Stop
  if($check.StartTime.ToUniversalTime() -ne $ownedStart -or $check.Path -ine $installedExe){throw 'Process identity changed before cleanup.'}
  # This is fixture cleanup, never evidence of the vendor's update exit/restart.
  Stop-Process -InputObject $check -Force
  if(-not $check.WaitForExit(15000)){throw 'Owned process did not terminate.'}
 }
}
$stage='input verification';$errorText=$null;$result='NOT_EXECUTED';$run=$null;$nativeOutcome=$null;$hookOutcome=$null
try {
 $art=(Resolve-Path $ArtifactRoot).Path
 if((Get-FileHash "$art\FILES-SHA256.json").Hash -ine 'd1ba4300e50388a7dbeb04c12f8a33132121b5bde182a16127e1a82413755bab'){throw 'Transfer manifest differs from the verified completed build.'}
 $files=Get-Content "$art\FILES-SHA256.json" -Raw|ConvertFrom-Json -DateKind String
 foreach($entry in $files){
  $path=[IO.Path]::GetFullPath((Join-Path $art $entry.Path))
  if(-not $path.StartsWith($art.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Artifact path escapes its root.'}
  if((Get-FileHash $path).Hash -ine $entry.Sha256 -or (Get-Item $path).Length -ne $entry.Bytes){throw "Artifact integrity failure: $($entry.Path)"}
 }
 $sourceA=Get-Content "$art\source-a\payload-manifest.json" -Raw|ConvertFrom-Json -DateKind String
 $patched=(Resolve-Path $PatchedArtifactRoot).Path
 $patchedFiles=Get-Content "$patched\FILES-SHA256.json" -Raw|ConvertFrom-Json -DateKind String
 foreach($entry in $patchedFiles){
  $path=[IO.Path]::GetFullPath((Join-Path $patched $entry.Path))
  if(-not $path.StartsWith($patched.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Patched artifact path escapes its root.'}
  if((Get-FileHash $path).Hash -ine $entry.Sha256 -or (Get-Item $path).Length -ne $entry.Bytes){throw 'Patched artifact integrity failure.'}
 }
 $sourceB=Get-Content "$patched\patched-b\payload-manifest.json" -Raw|ConvertFrom-Json -DateKind String
 $patchHash=(Get-FileHash "$PSScriptRoot\PRODUCT.patch").Hash
 if($sourceB.Kind -cne 'PatchedZip' -or $sourceB.PatchSha256 -ine $patchHash -or $sourceB.PreparationCommit -cne $env:GITHUB_SHA){throw 'Patched B is not bound to this reviewed source and Actions head.'}
 if($sourceA.PayloadSha256 -ine '0e0752c70fbd42c0bc8de5106a4a6e9a6e30ce1b34e8833cc17c13ef946946fc' -or $sourceA.SourceHead -cne $BaseSha -or $sourceB.SourceHead -cne $BaseSha){throw 'Artifact does not match the completed pinned build.'}
 Copy-Item "$art\driver-hook" "$root\driver-hook" -Recurse
 New-Item -ItemType Directory "$root\artifacts"|Out-Null
 Copy-Item "$art\source-a" "$root\artifacts" -Recurse
 Copy-Item "$patched\patched-b" "$root\artifacts" -Recurse
 Copy-Item "$patched\source-files.json" "$public\patched-source-files.json"
 Copy-Item "$patched\patched-b\payload-manifest.json" "$public\patched-b-manifest.json"
 $A="$root\artifacts\source-a\payload-manifest.json";$B="$root\artifacts\patched-b\payload-manifest.json"
 $stage='desktop qualification';Test-HostedDesktop $public
 $stage='diagnostic tool preparation'
 $dumpTool=& "$PSScriptRoot\inspector\Install-Inspector.ps1" -ToolsRoot "$root\inspector-tools"
 $stage='install A'
 [void](Assert-Target $root)
 $setup=Join-Path (Split-Path $A) $sourceA.InstallerFile
 if((Get-FileHash $setup).Hash -ine '8b859e25029ed8707db4219bc2104a4441c39a87e6ba52b40bfd26de0f16e5e2'){throw 'A installer changed.'}
 $install=Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/SP-','/NORESTART','/NOCLOSEAPPLICATIONS','/NORESTARTAPPLICATIONS','/TASKS=""',"/LOG=$root\install-A.log") -PassThru
 if(-not $install.WaitForExit(180000)){throw 'Installer timeout; no update will be attempted.'}
 Save-Json @{ExitCode=$install.ExitCode;InstallerSha256=$sourceA.InstallerSha256;Mode='Real Inno per-user silent install, no optional tasks or launch';InstalledPath=$installedExe} "$public\installation.json"
 if($install.ExitCode -ne 0){throw "A installer failed: $($install.ExitCode)"}
 if(@(Get-Process -Name OpenClaw.Tray.WinUI -ErrorAction SilentlyContinue).Count){throw 'Installer unexpectedly launched Companion.'}
 $stage='A smoke startup'
 & "$PSScriptRoot\native\Test-StartupRegistration.ps1" -WorkRoot $root -PayloadManifest $A -ExpectedVersion 2026.9.8-1 -Mode Smoke -TimeoutSeconds 180
 $smoke=@(Get-ChildItem "$root\evidence" -Directory -Filter startup-regression-*)
 if($smoke.Count -ne 1){throw 'Ambiguous smoke evidence.'}
 $binding=Get-Content (Join-Path $smoke[0].FullName 'native-binding.json') -Raw|ConvertFrom-Json -DateKind String
 Save-CompanionWindows ([int]$binding.ProcessId) $public 'A'
 Stop-OwnedCompanion
 $stage='actual vendor update'
 try {
  & "$PSScriptRoot\native\Invoke-ControlledUpdate.ps1" -WorkRoot $root -InstalledManifest $A -UpdateManifest $B -ExpectedVersion 2026.9.8-2 -TimeoutSeconds 180
  $nativeOutcome='UPDATE_PASSED_METADATA_CURRENT'
 } catch {
  if($_.Exception.Message.StartsWith('PRODUCT_REGRESSION_METADATA_STALE:')){$nativeOutcome='PRODUCT_REGRESSION_METADATA_STALE'}else{throw}
 }
 $runs=@(Get-ChildItem "$root\evidence" -Directory -Filter controlled-update-*)
 if($runs.Count -ne 1){throw 'Ambiguous controlled update identity.'}
 $run=$runs[0].FullName
 $transition=Get-Content "$run\transition.json" -Raw|ConvertFrom-Json -DateKind String
 Save-CompanionWindows ([int]$transition.NewPid) $public 'B'
 $stage='post-restart hook inspection'
 & "$PSScriptRoot\inspector\Test-HookAbsence.ps1" -WorkRoot $root -RunDirectory $run -UpdateManifest $B -DotnetDumpPath $dumpTool
 $hookResult=Get-Content "$run\hook-absence.json" -Raw|ConvertFrom-Json -DateKind String
 $hookOutcome=$hookResult.Result
 if($hookOutcome -cne 'PASS'){throw 'Post-restart hook absence not established.'}
 if($nativeOutcome -cne 'UPDATE_PASSED_METADATA_CURRENT'){throw 'Patched B still leaves stale metadata; native green proof failed.'}
 $result='PATCHED_UPDATE_VERIFIED'
 $stage='complete'
} catch {
 $errorText=$_.Exception.Message;$result='BLOCKED_OR_FAILED'
 try {
  foreach($p in @(Get-Process -Name OpenClaw.Tray.WinUI -ErrorAction SilentlyContinue)) {
   if($p.Path -ieq $installedExe -and $p.SessionId -eq $session -and $p.StartTime.ToUniversalTime() -ge $startUtc){Save-CompanionWindows $p.Id $public 'blocked'}
  }
 } catch {Write-Host 'Could not capture the blocked app window.'}
 Write-Host "Stopped at $stage : $errorText"
} finally {
 # Export only explicitly selected synthetic receipts; never configuration, credentials, memory dumps or arbitrary logs.
 $whitelist=@('before.json','after.json','native-binding.json','result.txt','transition.json','startup-result.json','hook-ready.json','driver-failed.json','vendor-script-created.json','unexpected-return.json','hook-absence.json','managed-assembly-names.json')
 foreach($file in Get-ChildItem "$root\evidence" -File -Recurse) {
  if($file.Name -in $whitelist){$relative=$file.FullName.Substring("$root\evidence\".Length);$destination=Join-Path "$public\native" $relative;New-Item -ItemType Directory (Split-Path $destination) -Force|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $destination}
 }
 if(Test-Path "$root\inspector-tools\inspector-tool.json"){Copy-Item "$root\inspector-tools\inspector-tool.json" $public}
 $appLog=Join-Path (Split-Path $installedExe) 'openclaw-tray.log'
 if(Test-Path $appLog){Get-Content $appLog|Where-Object {$_ -match 'Application started \(WinUI 3\)|Application shutting down|Application exiting'}|Set-Content "$public\startup-lines.txt" -Encoding utf8}
 try {Stop-OwnedCompanion;$cleanup='Owned Companion processes stopped; ephemeral VM disposal owns remaining fixture state.'}catch{$cleanup=$_.Exception.Message}
 Save-Json @{Result=$result;Stage=$stage;Error=$errorText;NativeOutcome=$nativeOutcome;HookAbsence=$hookOutcome;BaselineBuildRun=41215893003;PatchedBuildRun=$env:GITHUB_RUN_ID;ProductSource=$BaseSha;ProductPatchSha256=(Get-FileHash "$PSScriptRoot\PRODUCT.patch").Hash;PreparationCommit=$env:GITHUB_SHA;RunId=$env:GITHUB_RUN_ID;OS=(Get-CimInstance Win32_OperatingSystem).Caption;Windows11Proof=$false;UpdateBoundary='Controlled downloaded asset -> actual installed A process -> Updatum replacement -> actual B startup';SelectionAndNetworkDownloadTested=$false;Cleanup=$cleanup} "$public\native-result.json"
 $hashes=@(Get-ChildItem $public -Recurse -File|Sort-Object FullName|ForEach-Object {@{Path=$_.FullName.Substring($public.Length+1);Sha256=(Get-FileHash $_.FullName).Hash}})
 Save-Json $hashes "$public\FILES-SHA256.json"
}
if($result -eq 'BLOCKED_OR_FAILED'){throw "Native test incomplete at $stage. See native-result.json."}
Write-Host $result
