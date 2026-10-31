[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][string]$PayloadManifest,[Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][ValidateSet('Smoke','Regression')][string]$Mode,[string]$RestartReceipt,[string]$EvidenceDirectory,[ValidateRange(1,1800)][int]$TimeoutSeconds=180)
. "$PSScriptRoot\Native.Common.ps1"
$WorkRoot=Assert-Target $WorkRoot
$manifest=Get-Content -LiteralPath $PayloadManifest -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
if($manifest.ExpectedVersion -cne $ExpectedVersion -or $manifest.SourceHead -cne $BaseSha) {throw 'INPUT_MISMATCH: explicit expected version/source does not match candidate manifest.'}
$run=if($EvidenceDirectory){[IO.Path]::GetFullPath($EvidenceDirectory)}else{Join-Path "$WorkRoot\evidence" ('startup-regression-'+[Guid]::NewGuid().ToString('N'))}
if(-not $run.StartsWith("$WorkRoot\evidence\",[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $run)){throw 'Evidence must use a new task-owned directory.'}
[void](Assert-PlainPath $run)
New-Item -ItemType Directory -Path $run|Out-Null
try {
 if(-not $RestartReceipt) {
  if(@(Get-Process -Name 'OpenClaw.Tray.WinUI' -ErrorAction SilentlyContinue).Count){throw 'Exit only the task-owned app through its UI before standalone startup.'}
  Assert-PayloadInstalled $manifest
  $before=Get-InstalledSnapshot|ConvertTo-Json -Depth 12|ConvertFrom-Json -DateKind String
  if($Mode -eq 'Regression'){Assert-RegressionPrecondition $before $ExpectedVersion}
  $offset=Get-NativeLogPosition
  $p=[Diagnostics.Process]::Start((New-NativeProcessInfo (Get-InstalledExe)))
  $expectedPid=$p.Id;$expectedStart=$p.StartTime.ToUniversalTime().ToString('o')
 } else {
  if($Mode -cne 'Regression'){throw 'Driver restart observations are the regression lane, not smoke.'}
  $receipt=Get-Content -LiteralPath $RestartReceipt -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
  $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RestartReceipt))
  if(-not $parent.StartsWith("$WorkRoot\evidence\",[StringComparison]::OrdinalIgnoreCase)){throw 'Restart receipt must be task-owned.'}
  $beforePath=Join-Path $parent 'before.json'
  if((Get-FileHash $beforePath).Hash -ine $receipt.BeforeSnapshotSha256 -or (Get-FileHash $PayloadManifest).Hash -ine $receipt.UpdateManifestSha256 -or $manifest.PayloadSha256 -ine $receipt.PayloadSha256){throw 'Restart receipt inputs do not match.'}
  if($receipt.RestartLogOffset -le 0 -or [DateTime]$receipt.NewStartedUtc -lt [DateTime]$receipt.GateIssuedUtc -or ($receipt.NewPid -eq $receipt.OldPid -and $receipt.NewStartedUtc -eq $receipt.OldStartedUtc)){throw 'Restart receipt lacks a valid fresh process/log boundary.'}
  $before=Get-Content -LiteralPath $beforePath -Raw -Encoding UTF8|ConvertFrom-Json -DateKind String
  Assert-RegressionPrecondition $before $ExpectedVersion
  $expectedPid=[int]$receipt.NewPid;$expectedStart=$receipt.NewStartedUtc;$offset=[long]$receipt.RestartLogOffset
 }
 $before|ConvertTo-Json -Depth 12|Set-Content "$run\before.json" -Encoding UTF8
 $p=Wait-NativeStarted $expectedPid $offset $TimeoutSeconds
 if($p.StartTime.ToUniversalTime().ToString('o') -cne $expectedStart){throw 'STARTUP_OBSERVATION_BLOCKED: PID start identity changed.'}
 Assert-PayloadInstalled $manifest
 $after=Get-InstalledSnapshot|ConvertTo-Json -Depth 12|ConvertFrom-Json -DateKind String
 $after|ConvertTo-Json -Depth 12|Set-Content "$run\after.json" -Encoding UTF8
 [pscustomobject]@{Mode=$Mode;ProcessId=$p.Id;StartedUtc=$expectedStart;ExecutableSha256=(Get-FileHash (Get-InstalledExe)).Hash;SourceHead=$manifest.SourceHead;SourceManifestSha256=$manifest.SourceManifestSha256;PayloadSha256=$manifest.PayloadSha256;ExpectedVersion=$ExpectedVersion;LogOffset=$offset;FreshStartupMarker=$true}|ConvertTo-Json|Set-Content "$run\native-binding.json" -Encoding UTF8
 Assert-RegistrationAfterStartup $before $after $ExpectedVersion
 "PASS: real installed startup $Mode assertions passed."|Set-Content "$run\result.txt" -Encoding UTF8
 Write-Output "PASS: native startup $Mode. Evidence: $run"
} catch {
 $_.Exception.Message|Set-Content "$run\result.txt" -Encoding UTF8
 throw
}
# Smoke is fixture validation, not proof of stale-metadata repair. Retain this task app for visible proof.
