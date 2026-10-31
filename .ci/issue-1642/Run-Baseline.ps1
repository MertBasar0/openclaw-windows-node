# Pipeline/transport-component baseline only. Not native caller/backend proof.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Use PowerShell 7 on an already authorized Windows executor.' }
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
Push-Location $root
try {
    $head = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne 'ef1df54dfe95a8b0a2ae8033425561136d8a70ef') {
        throw 'Wrong baseline; reconcile source before execution.'
    }
    $production = & git status --porcelain -- src
    if ($LASTEXITCODE -ne 0 -or $production) { throw 'Production source must be unchanged.' }
    Get-Command dotnet -ErrorAction Stop | Out-Null
    $run = Join-Path $root ('.openclaw-proof/1642-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    # Run this script in its own pwsh process; overrides die with this process.
    $env:OPENCLAW_REPO_ROOT = $root
    $env:TEMP = Join-Path $run 'temp'
    $env:TMP = $env:TEMP
    $env:OPENCLAW_TRAY_DATA_DIR = Join-Path $run 'data'
    $env:OPENCLAW_TRAY_APPDATA_DIR = Join-Path $run 'appdata'
    $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR = Join-Path $run 'localappdata'
    @($env:TEMP, $env:OPENCLAW_TRAY_DATA_DIR, $env:OPENCLAW_TRAY_APPDATA_DIR,
      $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR) | ForEach-Object {
        New-Item -ItemType Directory -Path $_ | Out-Null
    }
    & dotnet test ./tests/OpenClaw.Tray.Tests/OpenClaw.Tray.Tests.csproj --filter 'FullyQualifiedName~Issue1642' --results-directory $run --logger 'trx;LogFileName=baseline.trx' 2>&1 | Tee-Object -FilePath (Join-Path $run 'dotnet.log')
    $testExit = $LASTEXITCODE
    $trxPath = Join-Path $run 'baseline.trx'
    if (-not (Test-Path -LiteralPath $trxPath)) { throw "No TRX: setup/build failure, not reproduction. See $run" }
    [xml]$trx = Get-Content -LiteralPath $trxPath -Raw
    $rows = @($trx.TestRun.Results.UnitTestResult)
    $failed = @($rows | Where-Object outcome -eq 'Failed')
    $passed = @($rows | Where-Object outcome -eq 'Passed')
    $expected = @('same-series-93-97', 'numeric-9-10', 'cross-base', 'unsorted-choose-greatest',
        'incompatible-highest', 'lower-vendor-stable-must-not-short-circuit',
        'final-after-same-base-alpha', 'invalid-release-metadata',
        'security-selected-metadata', 'ordinary-extended-stable-preserved')
    if ($testExit -ne 1 -or $rows.Count -ne 25 -or $failed.Count -ne 10 -or $passed.Count -ne 15) {
        throw "Unexpected result: exit=$testExit total=$($rows.Count) failed=$($failed.Count) passed=$($passed.Count). Preserve $run and investigate."
    }
    foreach ($name in $expected) {
        $matches = @($failed | Where-Object { $_.testName.Contains('PipelineOnly_DesiredSelection') -and $_.testName.Contains($name) })
        if ($matches.Count -ne 1) { throw "Missing exact expected failure: $name. See $run" }
        # Reject infrastructure exceptions masquerading as expected red cases.
        if ($matches[0].Output.ErrorInfo.Message -notmatch 'Assert\.(Equal|True|False)') {
            throw "Failure is not an expected assertion for $name. See $run"
        }
    }
    @{
        source = $head; scope = 'pipeline-only and transport-component';
        productPassed = $false; nativeCallerBackendProof = $false;
        expectedBaselineAssertionsObserved = $true; failed = 10; passed = 15;
        evidence = $trxPath
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'baseline-verdict.json')
    Write-Host "Expected baseline assertions observed. Product remains broken; caller/backend proof NOT performed. Evidence: $run"
} finally { Pop-Location }
