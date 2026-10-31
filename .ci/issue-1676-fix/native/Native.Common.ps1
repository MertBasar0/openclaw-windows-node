. "$PSScriptRoot\..\Common.ps1"
function Get-NativeLogPath { Join-Path (Split-Path -Parent (Get-InstalledExe)) 'openclaw-tray.log' }
function Get-NativeLogPosition {
 $path=Get-NativeLogPath
 if (Test-Path -LiteralPath $path) { return (Get-Item -LiteralPath $path).Length }
 return 0L
}
function Read-NewStartupMarker([long]$Offset) {
 $path=Get-NativeLogPath
 if (-not (Test-Path -LiteralPath $path)) { return $false }
 $f=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try {
  if ($f.Length -lt $Offset) { throw 'STARTUP_OBSERVATION_BLOCKED: log rotated; establish a new observation boundary.' }
  [void]$f.Seek($Offset,[IO.SeekOrigin]::Begin)
  $reader=[IO.StreamReader]::new($f)
  try { return $reader.ReadToEnd().Contains('Application started (WinUI 3)') } finally {$reader.Dispose()}
 } finally {$f.Dispose()}
}
function Get-InstalledSnapshot {
 $exe=Get-InstalledExe;$directory=Split-Path -Parent $exe;$views=[ordered]@{}
 foreach($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
  $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,$view);$key=$null
  try {
   $key=$base.OpenSubKey($RegistrySubkey,$false)
   if (-not $key) {throw 'FIXTURE_INVALID: production Inno registration missing.'}
   $values=[ordered]@{}
   foreach($name in ($key.GetValueNames() | Sort-Object)) {$values[$name]=[ordered]@{Kind=[string]$key.GetValueKind($name);Value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}}
   if ($values.Publisher.Value -cne 'OpenClaw Foundation' -or $values.InstallLocation.Value.TrimEnd('\') -ine $directory.TrimEnd('\') -or $values.UninstallString.Value -ine ('"'+(Join-Path $directory 'unins000.exe')+'"')) {throw 'FIXTURE_INVALID: registration does not match production per-user installation.'}
   $views[[string]$view]=$values
  } finally {if($key){$key.Dispose()};$base.Dispose()}
 }
 $files=[ordered]@{}
 foreach($name in @('OpenClaw.Tray.WinUI.exe','OpenClaw.Tray.WinUI.dll','unins000.exe','unins000.dat')) {$files[$name]=(Get-FileHash -LiteralPath (Join-Path $directory $name) -Algorithm SHA256).Hash}
 [pscustomobject]@{Registry=$views;Files=$files;Utc=[DateTime]::UtcNow.ToString('o')}
}
function Assert-PayloadInstalled($Manifest) {
 $directory=Split-Path -Parent (Get-InstalledExe)
 foreach($file in $Manifest.Files) {
  if ((Get-FileHash -LiteralPath (Join-Path $directory $file.Path) -Algorithm SHA256).Hash -ine $file.Sha256) {throw "PAYLOAD_MISMATCH: $($file.Path)"}
 }
 $version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $directory 'OpenClaw.Tray.WinUI.dll')).ProductVersion.Split('+')[0]
 if ($version -cne $Manifest.ExpectedVersion) {throw 'PAYLOAD_MISMATCH: version differs from independent expected version.'}
 if ((Get-Content -LiteralPath (Join-Path $directory 'app-identity.txt') -Raw).Trim() -cne 'release') {throw 'PAYLOAD_MISMATCH: not production identity.'}
}
function Wait-NativeStarted([int]$ExpectedPid,[long]$LogOffset,[int]$TimeoutSeconds) {
 $timer=[Diagnostics.Stopwatch]::StartNew()
 while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
  $all=@(Get-Process -Name 'OpenClaw.Tray.WinUI' -ErrorAction SilentlyContinue)
  if ($all.Count -gt 1) {throw 'OWNERSHIP_CONFLICT: multiple Companion processes.'}
  $p=Get-Process -Id $ExpectedPid -ErrorAction SilentlyContinue
  if (-not $p -or $p.Path -ine (Get-InstalledExe)) {throw 'STARTUP_BLOCKED: selected installed process exited or changed.'}
  if (Read-NewStartupMarker $LogOffset) {return $p}
  Start-Sleep -Milliseconds 200
 }
 throw 'STARTUP_BLOCKED: no fresh application-started marker. Inspect UI/onboarding; not regression red.'
}
function Assert-RegistrationAfterStartup($Before,$After,[string]$ExpectedVersion) {
 foreach($view in @('Registry64','Registry32')) {
  $b=$Before.Registry.$view;$a=$After.Registry.$view
  $bn=@($b.PSObject.Properties.Name|Sort-Object);$an=@($a.PSObject.Properties.Name|Sort-Object)
  if (($bn -join '|') -cne ($an -join '|')) {throw 'PRESERVATION_FAILURE: registry value names changed.'}
  foreach($name in $bn) {
   if($name -notin @('DisplayVersion','DisplayName')) {
    if($b.$name.Kind -cne $a.$name.Kind -or ($b.$name.Value|ConvertTo-Json -Compress -Depth 8) -cne ($a.$name.Value|ConvertTo-Json -Compress -Depth 8)) {throw "PRESERVATION_FAILURE: $name"}
   }
  }
  if($a.DisplayVersion.Kind -cne 'String' -or $a.DisplayName.Kind -cne 'String') {throw 'PRESERVATION_FAILURE: display metadata kinds changed.'}
 }
 foreach($name in @('unins000.exe','unins000.dat')) {if($Before.Files.$name -ine $After.Files.$name){throw "PRESERVATION_FAILURE: $name changed."}}
 # Last check: setup/payload/preservation failures must not masquerade as the named defect.
 foreach($view in @('Registry64','Registry32')) {
  $a=$After.Registry.$view
  if($a.DisplayVersion.Value -cne $ExpectedVersion -or $a.DisplayName.Value -cne "OpenClaw Companion version $ExpectedVersion") {throw "PRODUCT_REGRESSION_METADATA_STALE: $view did not reflect independently expected running release $ExpectedVersion."}
 }
}
function Assert-RegressionPrecondition($Before,[string]$ExpectedVersion) {
 if($ExpectedVersion -cne '2026.9.8-2'){throw 'REGRESSION_PRECONDITION_NOT_MET: expected controlled B version 2026.9.8-2.'}
 foreach($view in @('Registry64','Registry32')) {
  $v=$Before.Registry.$view
  if($v.DisplayVersion.Value -cne '2026.9.8-1' -or $v.DisplayName.Value -cne 'OpenClaw Companion version 2026.9.8-1') {throw 'REGRESSION_PRECONDITION_NOT_MET: need naturally stale A metadata, not already-correct metadata.'}
 }
}
function New-NativeProcessInfo([string]$Exe) {
 $info=[Diagnostics.ProcessStartInfo]::new($Exe);$info.UseShellExecute=$false
 foreach($name in @($info.EnvironmentVariables.Keys)) {
  if($name -like 'OPENCLAW_TRAY_*' -or $name -in @('DOTNET_STARTUP_HOOKS','OC1676_DRIVER_CONFIG','OPENCLAW_NATIVE_GATEWAY_DEV_PATCH')) {$info.EnvironmentVariables.Remove($name)}
 }
 $info.EnvironmentVariables['OPENCLAW_SKIP_UPDATE_CHECK']='1'
 return $info
}
