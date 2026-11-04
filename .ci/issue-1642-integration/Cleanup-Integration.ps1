[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node') { throw 'Disposable fork runner only.' }
$stateFile = Join-Path $env:RUNNER_TEMP 'openclaw-1642-cleanup.json'
if (-not (Test-Path $stateFile)) { Write-Host 'No remaining fixture state.'; exit 0 }
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
if ($state.id -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid cleanup owner.' }
$expectedWork = Join-Path $env:RUNNER_TEMP ('updater-proof-' + $state.id)
if (-not [string]::Equals([IO.Path]::GetFullPath($state.work), [IO.Path]::GetFullPath($expectedWork), 'OrdinalIgnoreCase')) {
    throw 'Cleanup path does not belong to this fixture.'
}
if ($state.proxyPid) {
    $process = Get-Process -Id $state.proxyPid -ErrorAction SilentlyContinue
    if ($process) {
        if ($process.StartTime.ToUniversalTime().Ticks -ne $state.proxyStartTicks -or $process.ProcessName -ne 'node') {
            throw 'PID no longer identifies the task-owned proxy; refusing termination.'
        }
        $process.Kill(); $process.WaitForExit(5000) | Out-Null
    }
}
if ($state.thumbprint) {
    if ($state.thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'Invalid certificate identity.' }
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        foreach ($cert in $store.Certificates.Find('FindByThumbprint',$state.thumbprint,$false)) {
            if (-not $cert.Subject.Contains('OpenClaw1642-' + $state.id)) { throw 'Certificate owner mismatch.' }
            $store.Remove($cert)
        }
        if ($store.Certificates.Find('FindByThumbprint',$state.thumbprint,$false).Count -ne 0) { throw 'Trust cleanup incomplete.' }
    } finally { $store.Dispose() }
}
foreach ($name in $state.ruleNames) {
    if ($name -cnotmatch ('^OpenClaw1642-' + $state.id + '-[0-9]+$')) { throw 'Firewall owner mismatch.' }
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop
}
if (Test-Path $expectedWork) { Remove-Item $expectedWork -Recurse -Force }
Remove-Item $stateFile
Write-Host 'Removed only this fixture certificate, rules, process and temporary files.'
