[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][ValidateSet('Prepare','Validate','Publish')][string]$Stage)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node' -or $env:GITHUB_REF -cne 'refs/heads/codex/issue-1676-fix-20261031'){throw 'Only the authorized hosted test branch may run this preparation.'}
$repo=(Resolve-Path $RepoRoot).Path
$output=[IO.Path]::GetFullPath($OutputRoot)
$workspace=[IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')+'\'
if(-not $output.StartsWith($workspace,[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be task-owned in this job workspace.'}
$evidence=Join-Path $output 'evidence'
$transfer=Join-Path $output 'transfer'
$sourceHead='a4dd026cc5f85a444a0fcd05eef5b86282dbda8c'
$patch=Join-Path $PSScriptRoot 'PRODUCT.patch'
$patchHash=(Get-FileHash $patch).Hash
function Save-Json($Value,[string]$Path){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding utf8}
function Require-Exit([string]$Name){if($LASTEXITCODE -ne 0){throw "$Name failed: exit $LASTEXITCODE"}}
function Assert-Source {
 if((& git rev-parse HEAD).Trim() -cne $sourceHead){throw 'Wrong product source.'};Require-Exit 'Source identity'
 $receipt=Get-Content "$evidence/preparation.json" -Raw|ConvertFrom-Json
 if($receipt.PatchSha256 -ine $patchHash -or $receipt.PreparationCommit -cne $env:GITHUB_SHA){throw 'Prepared source belongs to another patch or Actions head.'}
 foreach($file in (Get-Content "$evidence/source-files.json" -Raw|ConvertFrom-Json)){
  if((Get-FileHash (Join-Path $repo $file.Path)).Hash -ine $file.Sha256){throw "Product source changed: $($file.Path)"}
 }
}
Push-Location $repo
try {
 if($Stage -ceq 'Prepare'){
  if(Test-Path $output){throw 'Preparation output already exists.'}
  if((& git rev-parse HEAD).Trim() -cne $sourceHead){throw 'Wrong source baseline.'};Require-Exit 'Source identity'
  $dirty=@(& git status --porcelain);Require-Exit 'Source status';if($dirty.Count){throw 'Baseline must be clean.'}
  New-Item -ItemType Directory -Path $evidence,$transfer|Out-Null
  & git apply --check $patch;Require-Exit 'Patch applicability'
  & git apply $patch;Require-Exit 'Reviewed product patch'
  $paths=@(& git ls-files --cached --others --exclude-standard);Require-Exit 'Patched source inventory'
  $files=@($paths|Sort-Object -Unique|ForEach-Object{@{Path=$_;Sha256=(Get-FileHash (Join-Path $repo $_)).Hash}})
  Save-Json $files "$evidence/source-files.json"
  Save-Json @{ProductBase=$sourceHead;PatchSha256=$patchHash;PreparationCommit=$env:GITHUB_SHA;SourceManifestSha256=(Get-FileHash "$evidence/source-files.json").Hash} "$evidence/preparation.json"
  Copy-Item $patch "$evidence/PRODUCT.patch"
  return
 }
 Assert-Source
 $sdk=(& dotnet --version).Trim();Require-Exit 'SDK selection';if($sdk -cne '10.0.402'){throw 'Unexpected SDK.'}
 $env:OPENCLAW_REPO_ROOT=$repo
 $env:OPENCLAW_TRAY_DATA_DIR=Join-Path $output 'test-data'
 $env:OPENCLAW_TRAY_APPDATA_DIR=Join-Path $output 'test-roaming'
 $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR=Join-Path $output 'test-local'
 $env:TEMP=Join-Path $output 'temp';$env:TMP=$env:TEMP
 New-Item -ItemType Directory -Force -Path $env:TEMP,$env:OPENCLAW_TRAY_DATA_DIR,$env:OPENCLAW_TRAY_APPDATA_DIR,$env:OPENCLAW_TRAY_LOCALAPPDATA_DIR|Out-Null
 if($env:DOTNET_STARTUP_HOOKS -or $env:OC1676_DRIVER_CONFIG){throw 'Build/test process must not load the update hook.'}
 if($Stage -ceq 'Validate'){
  $checks=[Collections.Generic.List[object]]::new()
  & powershell.exe -NoProfile -File ./build.ps1 2>&1|Tee-Object "$evidence/full-build.log"
  $checks.Add(@{Name='FullBuild';ExitCode=$LASTEXITCODE;Command='./build.ps1'})
  foreach($suite in @('Shared','Tray')){
   $project="./tests/OpenClaw.$suite.Tests/OpenClaw.$suite.Tests.csproj"
   $results=Join-Path $evidence $suite
   # First execution intentionally restores; --no-restore on a fresh test tree can no-op.
   & dotnet test $project --logger "trx;LogFileName=$suite.trx" --results-directory $results 2>&1|Tee-Object "$evidence/$suite-tests.log"
   $exitCode=$LASTEXITCODE
   $trx=Join-Path $results "$suite.trx"
   $counts=$null;$valid=$false;$focused=$null
   if(Test-Path $trx){
    [xml]$xml=Get-Content $trx -Raw
    $c=$xml.TestRun.ResultSummary.Counters
    $counts=@{Total=[int]$c.total;Executed=[int]$c.executed;Passed=[int]$c.passed;Failed=[int]$c.failed;NotExecuted=[int]$c.notExecuted}
    $valid=($counts.Executed -gt 0 -and $counts.Failed -eq 0 -and $exitCode -eq 0)
    if($suite -ceq 'Tray'){
     $cases=@($xml.TestRun.Results.UnitTestResult|Where-Object testName -like '*InnoInstallationMetadataTests.*')
     $focused=@{Total=$cases.Count;Passed=@($cases|Where-Object outcome -eq 'Passed').Count;FailedOrSkipped=@($cases|Where-Object outcome -ne 'Passed').Count}
     $valid=$valid -and $focused.Total -eq 8 -and $focused.Passed -eq 8
    }
   }
   $checks.Add(@{Name=$suite;ExitCode=$exitCode;ValidExecutedReport=$valid;Counts=$counts;FocusedRegression=$focused;Command="dotnet test $project --logger trx --results-directory $results"})
  }
  Assert-Source
  $passed=$checks[0].ExitCode -eq 0 -and $checks[1].ValidExecutedReport -and $checks[2].ValidExecutedReport
  Save-Json @{Passed=$passed;Checks=$checks.ToArray();ProductBase=$sourceHead;PatchSha256=$patchHash;PreparationCommit=$env:GITHUB_SHA;SDK=$sdk;OS=(Get-CimInstance Win32_OperatingSystem).Caption;NativeUpdateExecuted=$false} "$evidence/validation-result.json"
  if(-not $passed){throw 'Required validation has failures or missing executed reports; evidence retained without waiver.'}
  return
 }
 $payload=Join-Path $output 'patched-b-publish'
 & dotnet publish ./src/OpenClaw.Tray.WinUI/OpenClaw.Tray.WinUI.csproj -c Release -r win-x64 --self-contained -o $payload -v:minimal -p:DevBuild=false -p:Version=2026.9.8-2 -p:InformationalVersion=2026.9.8-2 2>&1|Tee-Object "$evidence/patched-b-build.log"
 Require-Exit 'Patched B publish'
 $version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'OpenClaw.Tray.WinUI.dll')).ProductVersion.Split('+')[0]
 if($version -cne '2026.9.8-2' -or (Get-Content "$payload/app-identity.txt" -Raw).Trim() -cne 'release'){throw 'Wrong B version or identity.'}
 if(@(Get-ChildItem $payload -Recurse -File -Filter 'unins*').Count){throw 'Update ZIP must not carry an uninstaller.'}
 $contract=Get-Content "$PSScriptRoot/dependency-contract.json" -Raw|ConvertFrom-Json
 foreach($assembly in $contract.Assemblies){if((Get-FileHash (Join-Path $payload ($assembly.Name+'.dll'))).Hash -ine $assembly.Sha256){throw 'Dependency changed from the original inspected update contract.'}}
 Assert-Source
 $dest=Join-Path $transfer 'patched-b';New-Item -ItemType Directory $dest|Out-Null
 $files=@(Get-ChildItem $payload -Recurse -File|Sort-Object FullName|ForEach-Object{@{Path=$_.FullName.Substring($payload.Length+1);Sha256=(Get-FileHash $_.FullName).Hash}})
 $zip=Join-Path $dest 'payload.zip'
 [IO.Compression.ZipFile]::CreateFromDirectory($payload,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
 Save-Json @{Schema=2;Kind='PatchedZip';SourceHead=$sourceHead;PatchSha256=$patchHash;PreparationCommit=$env:GITHUB_SHA;SourceManifestSha256=(Get-FileHash "$evidence/source-files.json").Hash;ExpectedVersion=$version;PayloadFile='payload.zip';PayloadSha256=(Get-FileHash $zip).Hash;InstallerFile=$null;InstallerSha256=$null;Files=$files} "$dest/payload-manifest.json"
 Copy-Item "$evidence/source-files.json","$evidence/preparation.json" $transfer
 Copy-Item "$dest/payload-manifest.json" "$evidence/patched-b-manifest.json"
 $export=@(Get-ChildItem $transfer -Recurse -File|Sort-Object FullName|ForEach-Object{@{Path=$_.FullName.Substring($transfer.Length+1);Bytes=$_.Length;Sha256=(Get-FileHash $_.FullName).Hash}})
 Save-Json $export "$transfer/FILES-SHA256.json"
 Save-Json @{Result='PATCHED_B_BUILT';ProductBase=$sourceHead;PatchSha256=$patchHash;PreparationCommit=$env:GITHUB_SHA;ARebuilt=$false;HookRebuilt=$false;Installed=$false;NativeUpdateExecuted=$false} "$evidence/build-result.json"
} finally {Pop-Location}
