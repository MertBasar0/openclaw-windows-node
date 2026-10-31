[CmdletBinding()]
param([Parameter(Mandatory)][string]$ToolsRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node') { throw 'Inspector preparation requires the authorized disposable hosted Windows job.' }
$root = [IO.Path]::GetFullPath($ToolsRoot)
if ($root -notmatch '^C:\\OC1676[A-Za-z0-9_-]*\\' -or (Test-Path -LiteralPath $root)) { throw 'Use a fresh inspector tools directory inside the task C: root.' }
New-Item -ItemType Directory -Path $root | Out-Null
$feed = Join-Path $root 'feed'; New-Item -ItemType Directory -Path $feed | Out-Null
$package = Join-Path $feed 'dotnet-dump.10.0.750501.nupkg'
Invoke-WebRequest 'https://api.nuget.org/v3-flatcontainer/dotnet-dump/10.0.750501/dotnet-dump.10.0.750501.nupkg' -OutFile $package
if ((Get-FileHash -LiteralPath $package).Hash -ine 'ae70c9f37548e1e006467893e21ae41a005fefaf2270e29642b415df053324a7') { throw 'Microsoft inspector package differs from the reviewed pin.' }
$config = Join-Path $root 'NuGet.Config'
$escaped = [Security.SecurityElement]::Escape($feed)
"<configuration><packageSources><clear/><add key=`"verified-local-feed`" value=`"$escaped`"/></packageSources></configuration>" | Set-Content -LiteralPath $config -Encoding utf8
$bin = Join-Path $root 'bin'
& dotnet tool install dotnet-dump --tool-path $bin --version 10.0.750501 --configfile $config | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Task-local inspector installation failed.' }
$tool = Join-Path $bin 'dotnet-dump.exe'
$version = (& $tool --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^10\.0\.750501(?:\+|\s|$)') { throw 'Unexpected inspector version.' }
[ordered]@{Package='dotnet-dump';Version='10.0.750501';PackageSha256=(Get-FileHash $package).Hash;ExecutableSha256=(Get-FileHash $tool).Hash;SourceCommit='ad724c4b85e7ae775e42f393c6e95a7557a57954';Installation='task-local; no global tool or runtime/security-policy changes'} | ConvertTo-Json | Set-Content (Join-Path $root 'inspector-tool.json') -Encoding utf8
Write-Output $tool
