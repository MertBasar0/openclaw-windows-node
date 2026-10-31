[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$OutputRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node' -or $env:GITHUB_REF -cne 'refs/heads/codex/issue-1642-fix-20261101'){throw 'Only the authorized fresh hosted Windows test job may run this lane.'}
$repo=(Resolve-Path $RepoRoot).Path
$output=[IO.Path]::GetFullPath($OutputRoot)
$workspace=[IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')+'\'
if(-not $output.StartsWith($workspace,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $output)){throw 'Use a new output directory in this job workspace.'}
$evidence=Join-Path $output 'evidence'
New-Item -ItemType Directory -Path $evidence|Out-Null
$base='ef1df54dfe95a8b0a2ae8033425561136d8a70ef'
$patch=Join-Path $PSScriptRoot 'CANDIDATE.patch'
$expected=Get-Content "$PSScriptRoot/candidate-manifest.json" -Raw|ConvertFrom-Json -AsHashtable
$patchHash=(Get-FileHash $patch).Hash
function Save-Json($Value,[string]$Path){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding utf8}
function Require-Exit([string]$Name){if($LASTEXITCODE -ne 0){throw "$Name failed: exit $LASTEXITCODE"}}
function Assert-Source {
 foreach($file in $script:sourceFiles){if((Get-FileHash (Join-Path $repo $file.Path)).Hash -ine $file.Sha256){throw "Source changed during validation: $($file.Path)"}}
}
$checks=[Collections.Generic.List[object]]::new()
$stage='source preparation';$failure=$null;$passed=$false
Push-Location $repo
try {
 if((& git rev-parse HEAD).Trim() -cne $base){throw 'Wrong pinned product source.'};Require-Exit 'Source identity'
 $dirty=@(& git status --porcelain);Require-Exit 'Source status';if($dirty.Count){throw 'Product checkout must begin clean.'}
 if($expected.base -cne $base -or $patchHash -ine $expected.patches.'candidate.patch'){throw 'Candidate patch identity mismatch.'}
 & git apply --check $patch;Require-Exit 'Patch applicability'
 & git apply $patch;Require-Exit 'Patch application'
 foreach($path in $expected.files.Keys){if((Get-FileHash (Join-Path $repo $path)).Hash -ine $expected.files[$path].candidateSha256){throw "Candidate file mismatch: $path"}}
 $paths=@(& git ls-files --cached --others --exclude-standard);Require-Exit 'Source inventory'
 $script:sourceFiles=@($paths|Sort-Object -Unique|ForEach-Object{@{Path=$_;Sha256=(Get-FileHash (Join-Path $repo $_)).Hash}})
 Save-Json $sourceFiles "$evidence/source-files.json"
 Copy-Item $patch "$evidence/CANDIDATE.patch"
 Copy-Item "$PSScriptRoot/candidate-manifest.json" $evidence
 $stage='tool qualification'
 $sdk=(& dotnet --version).Trim();Require-Exit 'SDK selection';if($sdk -cne '10.0.402'){throw "Unexpected SDK: $sdk"}
 if($env:DOTNET_STARTUP_HOOKS -or $env:OC1676_DRIVER_CONFIG){throw 'Unexpected startup instrumentation.'}
 if(@(Get-Process -Name OpenClaw.Tray.WinUI -ErrorAction SilentlyContinue).Count){throw 'Fresh hosted job must not have Companion running.'}
 $env:OPENCLAW_REPO_ROOT=$repo
 $env:OPENCLAW_TRAY_DATA_DIR=Join-Path $output 'data'
 $env:OPENCLAW_TRAY_APPDATA_DIR=Join-Path $output 'roaming'
 $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR=Join-Path $output 'local'
 $env:TEMP=Join-Path $output 'temp';$env:TMP=$env:TEMP
 New-Item -ItemType Directory -Path $env:TEMP,$env:OPENCLAW_TRAY_DATA_DIR,$env:OPENCLAW_TRAY_APPDATA_DIR,$env:OPENCLAW_TRAY_LOCALAPPDATA_DIR|Out-Null
 Save-Json @{SourceBase=$base;PatchSha256=$patchHash;PreparationCommit=$env:GITHUB_SHA;SDK=$sdk;OS=(Get-CimInstance Win32_OperatingSystem).Caption;Image=$env:ImageOS;ImageVersion=$env:ImageVersion;Windows11Proof=$false;NativeCallerBackendProof=$false} "$evidence/runner.json"
 $stage='full build'
 & powershell.exe -NoProfile -File ./build.ps1 2>&1|Tee-Object "$evidence/full-build.log"
 $checks.Add(@{Name='FullBuild';ExitCode=$LASTEXITCODE;Command='./build.ps1'})
 foreach($suite in @('Shared','Tray')){
  $stage="$suite tests"
  $project="./tests/OpenClaw.$suite.Tests/OpenClaw.$suite.Tests.csproj"
  $results=Join-Path $evidence $suite
  # Restore on first execution; --no-restore can silently no-op in a fresh tree.
  & dotnet test $project --logger "trx;LogFileName=$suite.trx" --results-directory $results 2>&1|Tee-Object "$evidence/$suite-tests.log"
  $exitCode=$LASTEXITCODE;$trx=Join-Path $results "$suite.trx"
  $counts=$null;$focused=$null;$valid=$false
  if(Test-Path $trx){
   [xml]$xml=Get-Content $trx -Raw
   $rows=@($xml.TestRun.Results.UnitTestResult)
   $counts=@{Total=$rows.Count;Passed=@($rows|Where-Object outcome -eq 'Passed').Count;Failed=@($rows|Where-Object outcome -eq 'Failed').Count;Skipped=@($rows|Where-Object outcome -eq 'NotExecuted').Count;Other=@($rows|Where-Object outcome -notin @('Passed','Failed','NotExecuted')).Count}
   $valid=$exitCode -eq 0 -and $counts.Passed -gt 0 -and $counts.Failed -eq 0 -and $counts.Other -eq 0
   if($suite -ceq 'Tray'){
    $cases=@($rows|Where-Object testName -like '*Issue1642*')
    $focused=@{Total=$cases.Count;Passed=@($cases|Where-Object outcome -eq 'Passed').Count;FailedOrSkipped=@($cases|Where-Object outcome -ne 'Passed').Count;Names=@($cases|ForEach-Object testName)}
    $valid=$valid -and $focused.Total -eq 25 -and $focused.Passed -eq 25
   }
  }
  $checks.Add(@{Name=$suite;ExitCode=$exitCode;ValidExecutedReport=$valid;Counts=$counts;Issue1642=$focused;Command="dotnet test $project --logger trx --results-directory $results"})
 }
 $stage='source preservation'
 Assert-Source
 $passed=$checks[0].ExitCode -eq 0 -and $checks[1].ValidExecutedReport -and $checks[2].ValidExecutedReport
 $stage='complete'
 if(-not $passed){throw 'Normal green validation failed or had missing execution; no baseline expected-red exception is accepted.'}
} catch {
 $failure=$_.Exception.Message
 throw
} finally {
 Save-Json @{Result=$(if($passed){'PATCHED_PIPELINE_TESTS_PASSED'}else{'FAILED_OR_INCOMPLETE'});Passed=$passed;Stage=$stage;Failure=$failure;Checks=$checks.ToArray();ProductBase=$base;PatchSha256=$patchHash;PreparationCommit=$env:GITHUB_SHA;NativeCallerBackendProof=$false;InstallationOrActivationTested=$false;FixtureScope='Standalone HTTP fixture, not wired to production Updatum transport';BaselineTestPatchUnchanged=$true} "$evidence/validation-result.json"
 $files=@(Get-ChildItem $evidence -File -Recurse|Sort-Object FullName|ForEach-Object{@{Path=$_.FullName.Substring($evidence.Length+1);Sha256=(Get-FileHash $_.FullName).Hash}})
 Save-Json $files "$evidence/FILES-SHA256.json"
 Pop-Location
}
