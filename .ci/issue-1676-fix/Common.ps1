Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseSha = 'a4dd026cc5f85a444a0fcd05eef5b86282dbda8c'
$RegistrySubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{M0LTB0T-TRAY-4PP1-D3N7}_is1'
function Assert-NativeWindows {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native Windows required. WSL is not native proof.' }
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'This kit pins x64 artifacts; use an x64 Windows process.' }
    if (-not ('Issue1676PackageIdentity' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; public static class Issue1676PackageIdentity { [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern int GetCurrentPackageFullName(ref uint length, IntPtr name); }'
    }
    [uint32]$length = 0
    if ([Issue1676PackageIdentity]::GetCurrentPackageFullName([ref]$length, [IntPtr]::Zero) -ne 15700) { throw 'Use unpackaged PowerShell launched from Explorer, not a packaged application.' }
}
function Assert-PlainPath([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    if ($p -notmatch '^C:\\') { throw 'Use a task-owned C: directory inside the disposable VM.' }
    $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
    if (-not $item) { $item = Get-Item -LiteralPath (Split-Path -Parent $p) }
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse path refused: $($item.FullName)" }
        $item = $item.Parent
    }
    return $p
}
function Assert-Target([string]$Root) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node' -or $env:GITHUB_REF -cne 'refs/heads/codex/issue-1676-fix-20261031') { throw 'This adapted lane is restricted to its authorized GitHub-hosted test branch.' }
    Assert-NativeWindows
    $rootPath = Assert-PlainPath $Root
    $receipt = Get-Content -LiteralPath (Join-Path $rootPath 'target.local.json') -Raw | ConvertFrom-Json -DateKind String
    if ($receipt.Root -ne $rootPath -or $receipt.Computer -ne $env:COMPUTERNAME -or $receipt.Sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Target receipt does not match this VM, user, and root.' }
    if ($receipt.Provider -cne 'GitHub-hosted' -or $receipt.RunId -cne $env:GITHUB_RUN_ID -or $receipt.RunAttempt -cne $env:GITHUB_RUN_ATTEMPT -or $receipt.SnapshotAvailable -ne $false) { throw 'Target is not the recorded ephemeral Actions job.' }
    return $rootPath
}
function Set-BuildEnvironment([string]$Root,[string]$Repo) {
    $env:OPENCLAW_REPO_ROOT = $Repo
    $env:OPENCLAW_TRAY_DATA_DIR = Join-Path $Root 'test-data'
    $env:OPENCLAW_TRAY_APPDATA_DIR = Join-Path $Root 'test-roaming'
    $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR = Join-Path $Root 'test-local'
    $env:TEMP = Join-Path $Root 'temp'; $env:TMP = $env:TEMP
    foreach ($p in @($env:OPENCLAW_TRAY_DATA_DIR,$env:OPENCLAW_TRAY_APPDATA_DIR,$env:OPENCLAW_TRAY_LOCALAPPDATA_DIR,$env:TEMP)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
function Set-NativeEnvironment {
    # The disposable VM is the OS boundary. IsIsolated suppresses persistent integrations.
    foreach ($v in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'OPENCLAW_TRAY_*' -or $_.Name -in @('OPENCLAW_SKIP_UPDATE_CHECK','OPENCLAW_GATEWAY_FIXTURE_MODE','OPENCLAW_NATIVE_GATEWAY_DEV_PATCH') })) { Remove-Item -LiteralPath ('Env:' + $v.Name) }
}
function Get-InstalledExe { return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenClawTray\OpenClaw.Tray.WinUI.exe' }
function Assert-Exit([string]$Command) { if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit $LASTEXITCODE" } }
