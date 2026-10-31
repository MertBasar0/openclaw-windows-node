[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$OutputRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node') {
    throw 'This build entry point is only for the authorized disposable GitHub-hosted Windows job.'
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$output = [IO.Path]::GetFullPath($OutputRoot)
$workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') + '\'
if (-not $output.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) {
    throw 'Use a new output directory inside this job workspace.'
}
$sourceHead = 'a4dd026cc5f85a444a0fcd05eef5b86282dbda8c'
$evidence = Join-Path $output 'evidence'
$transfer = Join-Path $output 'transfer'
New-Item -ItemType Directory -Path $evidence, $transfer | Out-Null
function Save-Json($Value, [string]$Path) { $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Require-Exit([string]$Operation) { if ($LASTEXITCODE -ne 0) { throw "$Operation failed: exit $LASTEXITCODE" } }
function Require-NoInstallation {
    if (@(Get-Process -Name OpenClaw.Tray.WinUI -ErrorAction SilentlyContinue).Count) { throw 'Companion is running; this is not a clean build-only job.' }
    foreach ($folder in @($env:LOCALAPPDATA, $env:APPDATA)) {
        if (Test-Path -LiteralPath (Join-Path $folder 'OpenClawTray')) { throw 'Companion state exists in this build-only job.' }
    }
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $key = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\{M0LTB0T-TRAY-4PP1-D3N7}_is1')
                if ($key) { $key.Dispose(); throw 'Existing Companion registration; refusing to borrow the installation.' }
            } finally { $base.Dispose() }
        }
    }
}
function Save-Payload([string]$Name, [string]$Kind, [string]$Payload, [string]$Version, [string]$Installer) {
    $dest = Join-Path $transfer $Name
    New-Item -ItemType Directory -Path $dest | Out-Null
    $actual = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $Payload 'OpenClaw.Tray.WinUI.dll')).ProductVersion.Split('+')[0]
    if ($actual -cne $Version) { throw "Payload version mismatch: expected $Version, observed $actual" }
    if ((Get-Content (Join-Path $Payload 'app-identity.txt') -Raw).Trim() -cne 'release') { throw 'Expected release-identity test payload.' }
    if (@(Get-ChildItem -LiteralPath $Payload -Recurse -File -Filter 'unins*').Count) { throw 'ZIP payload must not contain an uninstaller.' }
    foreach ($assembly in $contract.Assemblies) {
        if ((Get-FileHash -LiteralPath (Join-Path $Payload ($assembly.Name + '.dll'))).Hash -ine $assembly.Sha256) { throw 'Published dependency differs from the inspected contract.' }
    }
    $files = @(Get-ChildItem -LiteralPath $Payload -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{ Path = $_.FullName.Substring($Payload.Length + 1); Sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash }
    })
    $zip = Join-Path $dest 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($Payload, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $installerFile = $null; $installerHash = $null
    if ($Installer) {
        $installerFile = 'baseline-Setup-x64.exe'
        Copy-Item -LiteralPath $Installer -Destination (Join-Path $dest $installerFile)
        $installerHash = (Get-FileHash -LiteralPath (Join-Path $dest $installerFile)).Hash
    }
    Save-Json ([ordered]@{Schema=2; Kind=$Kind; SourceHead=$sourceHead; SourceManifestSha256=$sourceManifestHash; ExpectedVersion=$Version; PayloadFile='payload.zip'; PayloadSha256=(Get-FileHash $zip).Hash; InstallerFile=$installerFile; InstallerSha256=$installerHash; Files=$files}) (Join-Path $dest 'payload-manifest.json')
}
Push-Location $repo
try {
    if ((& git rev-parse HEAD).Trim() -cne $sourceHead) { throw 'Unexpected product source.' }; Require-Exit 'Source identity'
    $dirty = @(& git status --porcelain); Require-Exit 'Source status'
    if ($dirty.Count) { throw 'Product checkout must start clean.' }
    Require-NoInstallation
    if ($env:DOTNET_STARTUP_HOOKS -or $env:OC1676_DRIVER_CONFIG) { throw 'Unexpected startup instrumentation in build environment.' }
    $manifest = Get-Content (Join-Path $PSScriptRoot 'INPUT-SHA256.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $entry.Name)).Hash -ine $entry.Value) { throw "Reviewed input changed: $($entry.Name)" }
    }
    $sdk = (& dotnet --version).Trim(); Require-Exit 'SDK selection'
    if ($sdk -cne '10.0.402') { throw "Unexpected SDK: $sdk" }
    $env:OPENCLAW_REPO_ROOT = $repo
    $env:OPENCLAW_TRAY_DATA_DIR = Join-Path $output 'build-data'
    $env:OPENCLAW_TRAY_APPDATA_DIR = Join-Path $output 'build-roaming'
    $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR = Join-Path $output 'build-local'
    $env:TEMP = Join-Path $output 'temp'; $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP, $env:OPENCLAW_TRAY_DATA_DIR, $env:OPENCLAW_TRAY_APPDATA_DIR, $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR | Out-Null

    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Preinstalled Inno Setup compiler missing.' }
    $os = Get-CimInstance Win32_OperatingSystem
    $processSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $explorerPresent = [bool](@(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $processSession).Count)
    $facts = [ordered]@{
        PreparationCommit=$env:GITHUB_SHA; ProductSource=$sourceHead; Image=$env:ImageOS; ImageVersion=$env:ImageVersion
        OS=$os.Caption; OSVersion=$os.Version; Architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        SDK=$sdk; InnoVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($iscc).ProductVersion
        UserInteractive=[Environment]::UserInteractive; ProcessSession=$processSession; ExplorerInSameSession=$explorerPresent
        WingetAvailable=[bool](Get-Command winget -ErrorAction SilentlyContinue); DotnetDumpAvailable=[bool](Get-Command dotnet-dump -ErrorAction SilentlyContinue)
        NativeUpdateQualified=$false; Reason='Build-only hosted Server environment; interactive Windows 11 installation/update and diagnostic capabilities remain unverified.'
    }
    Save-Json $facts (Join-Path $evidence 'runner.json')
    $sourcePaths = @(& git ls-files); Require-Exit 'Tracked source inventory'
    $sourceFiles = @($sourcePaths | ForEach-Object { [ordered]@{Path=$_; Sha256=(Get-FileHash -LiteralPath (Join-Path $repo $_)).Hash} })
    Save-Json $sourceFiles (Join-Path $evidence 'source-files.json')
    $sourceManifestHash = (Get-FileHash (Join-Path $evidence 'source-files.json')).Hash

    $contract = Get-Content (Join-Path $PSScriptRoot 'dependency-contract.json') -Raw | ConvertFrom-Json
    $deps = Join-Path $output 'driver-deps'; New-Item -ItemType Directory -Path $deps | Out-Null
    foreach ($package in $contract.Packages) {
        $id = if ($package.File -ceq 'updatum.1.3.4.nupkg') { 'updatum/1.3.4' } elseif ($package.File -ceq 'octokit.14.0.0.nupkg') { 'octokit/14.0.0' } else { throw 'Unexpected dependency.' }
        $file = Join-Path $deps $package.File
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/$id/$($package.File)" -OutFile $file
        if ((Get-FileHash -LiteralPath $file).Hash -ine $package.Sha256) { throw 'Dependency archive hash mismatch.' }
        [IO.Compression.ZipFile]::ExtractToDirectory($file, (Join-Path $deps ([IO.Path]::GetFileNameWithoutExtension($package.File))))
    }
    foreach ($assembly in $contract.Assemblies) {
        if ((Get-FileHash -LiteralPath (Join-Path $deps $assembly.RelativePath)).Hash -ine $assembly.Sha256) { throw 'Dependency assembly hash mismatch.' }
    }
    $hookOut = Join-Path $transfer 'driver-hook'
    & dotnet build (Join-Path $PSScriptRoot 'native/Issue1676.StartupHook.csproj') -c Release -o $hookOut "-p:ReferenceRoot=$deps" "-p:BaseIntermediateOutputPath=$output\driver-obj\" 2>&1 | Tee-Object (Join-Path $evidence 'hook-build.log')
    Require-Exit 'Hook build'
    Save-Json ([ordered]@{SourceSha256=(Get-FileHash (Join-Path $PSScriptRoot 'native/StartupHook.cs')).Hash; ProjectSha256=(Get-FileHash (Join-Path $PSScriptRoot 'native/Issue1676.StartupHook.csproj')).Hash; DependencyContractSha256=(Get-FileHash (Join-Path $PSScriptRoot 'dependency-contract.json')).Hash; SdkVersion=$sdk; TargetFramework='net10.0'; Configuration='Release'; HookSha256=(Get-FileHash (Join-Path $hookOut 'Issue1676.StartupHook.dll')).Hash; UpdatumSourceCommit=$contract.UpdatumSourceCommit}) (Join-Path $hookOut 'hook-receipt.json')
    Copy-Item -LiteralPath (Join-Path $hookOut 'hook-receipt.json') -Destination $evidence

    & powershell.exe -NoProfile -File ./scripts/build-inno-local.ps1 -Arch x64 -Configuration Release -Version 2026.9.8-1 2>&1 | Tee-Object (Join-Path $evidence 'source-a-build.log')
    Require-Exit 'A Inno build'
    Save-Payload 'source-a' 'InitialInno' (Join-Path $repo 'publish-local-x64') '2026.9.8-1' (Join-Path $repo 'Output/OpenClawCompanion-Setup-x64.exe')

    $bPayload = Join-Path $output 'base-b-publish'
    & dotnet publish ./src/OpenClaw.Tray.WinUI/OpenClaw.Tray.WinUI.csproj -c Release -r win-x64 --self-contained -o $bPayload -v:minimal -p:DevBuild=false -p:Version=2026.9.8-2 -p:InformationalVersion=2026.9.8-2 2>&1 | Tee-Object (Join-Path $evidence 'base-b-build.log')
    Require-Exit 'B ZIP publish'
    Save-Payload 'base-b' 'BaselineZip' $bPayload '2026.9.8-2' ''

    foreach ($entry in $sourceFiles) {
        if ((Get-FileHash -LiteralPath (Join-Path $repo $entry.Path)).Hash -ine $entry.Sha256) { throw "Tracked source changed: $($entry.Path)" }
    }
    $trackedChanges = @(& git status --porcelain --untracked-files=no); Require-Exit 'Final source status'
    if ($trackedChanges.Count) { throw 'Build changed tracked product files.' }
    Require-NoInstallation
    Copy-Item -LiteralPath (Join-Path $evidence 'source-files.json') -Destination $transfer
    Copy-Item -LiteralPath (Join-Path $transfer 'source-a/payload-manifest.json') -Destination (Join-Path $evidence 'source-a-manifest.json')
    Copy-Item -LiteralPath (Join-Path $transfer 'base-b/payload-manifest.json') -Destination (Join-Path $evidence 'base-b-manifest.json')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'NEXT-NATIVE-STEP.md') -Destination $transfer
    $exportFiles = @(Get-ChildItem -LiteralPath $transfer -File -Recurse | Sort-Object FullName | ForEach-Object { [ordered]@{Path=$_.FullName.Substring($transfer.Length+1);Bytes=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash} })
    Save-Json $exportFiles (Join-Path $transfer 'FILES-SHA256.json')
    Save-Json $exportFiles (Join-Path $evidence 'export-files.json')
    Save-Json ([ordered]@{Result='BUILD_PREPARATION_PASSED'; SourceHead=$sourceHead; HookCompiled=$true; AInstallerBuilt=$true; BZipBuilt=$true; ProductChanged=$false; Installed=$false; Launched=$false; NativeUpdateExecuted=$false; PostRestartHookAbsence='UNVERIFIED'; Windows11UIProof=$false}) (Join-Path $evidence 'build-result.json')
} catch {
    Save-Json ([ordered]@{Result='BUILD_PREPARATION_FAILED'; Error=$_.Exception.Message; NativeUpdateExecuted=$false; ProductDefectReproduced=$false}) (Join-Path $evidence 'build-result.json')
    throw
} finally { Pop-Location }
