[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true') {
    throw 'This preparation is for the authorized GitHub-hosted Windows job only.'
}
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$manifest = Get-Content (Join-Path $PSScriptRoot 'SHA256SUMS.json') -Raw | ConvertFrom-Json -AsHashtable
foreach ($name in $manifest.Keys) {
    $actual = (Get-FileHash (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $manifest[$name]) { throw "Input hash mismatch: $name" }
}
Push-Location $root
try {
    $head = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne 'ef1df54dfe95a8b0a2ae8033425561136d8a70ef') {
        throw 'Unexpected baseline source.'
    }
    $status = & git status --porcelain
    if ($LASTEXITCODE -ne 0 -or $status) { throw 'Expected a fresh clean baseline checkout.' }
    & git apply --check (Join-Path $PSScriptRoot 'test-only.patch')
    if ($LASTEXITCODE -ne 0) { throw 'Patch check failed.' }
    & git apply (Join-Path $PSScriptRoot 'test-only.patch')
    if ($LASTEXITCODE -ne 0) { throw 'Patch apply failed; retain evidence, do not retry.' }
    $expected = Get-Content (Join-Path $PSScriptRoot 'expected-test-files.json') -Raw | ConvertFrom-Json -AsHashtable
    $newFiles = @(& git ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0 -or @(Compare-Object @($expected.Keys | Sort-Object) @($newFiles | Sort-Object)).Count -ne 0) {
        throw 'Patch produced unexpected files.'
    }
    & git diff --exit-code
    if ($LASTEXITCODE -ne 0) { throw 'An existing source file changed.' }
    foreach ($name in $expected.Keys) {
        $actual = (Get-FileHash (Join-Path $root $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected[$name]) { throw "Patched test differs from reviewed kit: $name" }
    }
    Write-Host "Verified unchanged baseline $head and four test-only additions."
} finally { Pop-Location }
