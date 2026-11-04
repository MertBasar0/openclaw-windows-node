[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
$sourceSha = '4265c3ab5ed2f0daceb019741a1f707d74d1105e'
$expectedRef = 'refs/heads/openclaw/issue-1642-integration-proof'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -cne 'MertBasar0/openclaw-windows-node' -or $env:GITHUB_REF -cne $expectedRef) {
    throw 'Restricted to the authorized disposable fork Windows job.'
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'x64 runner required.' }
Get-Command dotnet, node, New-NetFirewallRule, Get-NetFirewallProfile -ErrorAction Stop | Out-Null
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$evidence = [IO.Path]::GetFullPath($EvidenceRoot)
$id = [Guid]::NewGuid().ToString('N')
$work = Join-Path $env:RUNNER_TEMP ('updater-proof-' + $id)
New-Item -ItemType Directory -Path $work, $evidence | Out-Null
$env:OPENCLAW_REPO_ROOT = $repo
$env:TEMP = Join-Path $work 'temp'
$env:TMP = $env:TEMP
$env:OPENCLAW_TRAY_DATA_DIR = Join-Path $work 'data'
$env:OPENCLAW_TRAY_APPDATA_DIR = Join-Path $work 'roaming'
$env:OPENCLAW_TRAY_LOCALAPPDATA_DIR = Join-Path $work 'local'
@($env:TEMP, $env:OPENCLAW_TRAY_DATA_DIR, $env:OPENCLAW_TRAY_APPDATA_DIR,
  $env:OPENCLAW_TRAY_LOCALAPPDATA_DIR) | ForEach-Object { New-Item -ItemType Directory -Path $_ | Out-Null }
$proxy = $null; $certificate = $null; $rootCertificate = $null; $key = $null; $store = $null
$ruleNames = [System.Collections.Generic.List[string]]::new()
$stage = 'source-admission'; $passed = $false; $failure = $null
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$cleanupFile = Join-Path $env:RUNNER_TEMP 'openclaw-1642-cleanup.json'
function Save-CleanupState {
    @{ id = $id; thumbprint = if ($rootCertificate) { $rootCertificate.Thumbprint } else { $null };
       ruleNames = @($ruleNames.ToArray()); work = $work; proxyPid = if ($proxy) { $proxy.Id } else { $null }; proxyStartTicks = if ($proxy) { $proxy.StartTime.ToUniversalTime().Ticks } else { $null } } |
       ConvertTo-Json | Set-Content $cleanupFile
}
Save-CleanupState
Push-Location $repo
try {
    if ((& git rev-parse HEAD).Trim() -ne $sourceSha -or $LASTEXITCODE -ne 0) { throw 'Unexpected source revision.' }
    if (& git status --porcelain) { throw 'Fresh product checkout is not clean.' }
    $project = Join-Path $repo 'tests/OpenClaw.Tray.Tests/OpenClaw.Tray.Tests.csproj'
    [xml]$app = Get-Content ./src/OpenClaw.Tray.WinUI/OpenClaw.Tray.WinUI.csproj -Raw
    $vendor = @($app.Project.ItemGroup.PackageReference | Where-Object Include -eq 'Updatum')
    if ($vendor.Count -ne 1 -or $vendor[0].Version -ne '1.3.4') { throw 'Pinned vendor contract changed.' }
    [xml]$testProject = Get-Content $project -Raw
    if (@($testProject.Project.ItemGroup.PackageReference | Where-Object Include -eq 'Updatum').Count -gt 0) {
        throw 'Test project already references Updatum; reconcile instead of overwriting.'
    }
    $group = $testProject.CreateElement('ItemGroup')
    $package = $testProject.CreateElement('PackageReference')
    $package.SetAttribute('Include', 'Updatum'); $package.SetAttribute('Version', '1.3.4')
    [void]$group.AppendChild($package)
    $compile = $testProject.CreateElement('Compile')
    $compile.SetAttribute('Include', '../../src/OpenClaw.Tray.WinUI/Services/UpdatumUpdateBackend.cs')
    $compile.SetAttribute('Link', 'Services/UpdatumUpdateBackend.cs')
    [void]$group.AppendChild($compile); [void]$testProject.Project.AppendChild($group)
    $testProject.Save($project)
    $testFile = Join-Path $repo 'tests/OpenClaw.Tray.Tests/ProductionUpdaterIntegrationTests.cs'
    if (Test-Path $testFile) { throw 'Proof test already exists.' }
    Copy-Item (Join-Path $PSScriptRoot 'ProductionUpdaterIntegrationTests.cs') $testFile
    $expected = @('tests/OpenClaw.Tray.Tests/OpenClaw.Tray.Tests.csproj', 'tests/OpenClaw.Tray.Tests/ProductionUpdaterIntegrationTests.cs')
    $changed = @(& git ls-files --modified --others --exclude-standard)
    if (@(Compare-Object ($expected | Sort-Object) ($changed | Sort-Object)).Count -ne 0) { throw 'Unexpected preparation paths.' }
    & git diff --quiet HEAD -- src docs
    if ($LASTEXITCODE -ne 0) { throw 'Production source changed.' }
    $sourceFiles = @('src/OpenClaw.Tray.WinUI/Services/UpdatumUpdateBackend.cs','src/OpenClaw.Tray.WinUI/Services/UpdateCheckPipeline.cs','src/OpenClaw.Shared/OpenClawReleaseVersion.cs')
    @($sourceFiles | ForEach-Object { @{ path = $_; sha256 = (Get-FileHash -Algorithm SHA256 $_).Hash } }) | ConvertTo-Json | Set-Content (Join-Path $evidence 'production-source-hashes.json')
    $stage = 'compile'
    & dotnet --info | Set-Content (Join-Path $evidence 'dotnet-info.txt')
    & node --version | Set-Content (Join-Path $evidence 'node-version.txt')
    & dotnet build $project -c Release -r win-x64 --disable-build-servers --verbosity minimal 2>&1 |
        Tee-Object -FilePath (Join-Path $evidence 'build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Proof project compilation failed.' }
    $stage = 'network-isolation'
    if (@(Get-NetFirewallProfile | Where-Object { $_.Enabled.ToString() -ne 'True' }).Count -gt 0) {
        throw 'Firewall is not active; refusing unguarded proof, no global policy change made.'
    }
    $testhosts = @(Get-ChildItem ./tests/OpenClaw.Tray.Tests/bin -Recurse -Filter testhost.exe |
        Where-Object { $_.FullName -match 'Release' -and $_.FullName -match 'win-x64' })
    if ($testhosts.Count -eq 0) { throw 'No compiled testhost.exe found.' }
    $programs = @((Get-Command dotnet).Source) + @($testhosts.FullName)
    foreach ($program in ($programs | Select-Object -Unique)) {
        $rule = 'OpenClaw1642-' + $id + '-' + $ruleNames.Count
        $ruleNames.Add($rule); Save-CleanupState
        $parameters = @{ Name = $rule; DisplayName = $rule; Direction = 'Outbound'; Action = 'Block';
            Program = $program; Profile = 'Any'; Enabled = 'True';
            RemoteAddress = 'Any' }
        New-NetFirewallRule @parameters | Out-Null
    }
    $ruleReceipt = @(foreach ($name in $ruleNames) {
        $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name $name -ErrorAction Stop
        $addresses = @($rule | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress)
        if ($addresses.Count -ne 1 -or $addresses[0] -ne 'Any') { throw 'External egress block did not cover all addresses.' }
        if ($rule.Enabled.ToString() -ne 'True' -or $rule.Action -ne 'Block') { throw 'Egress rule inactive.' }
        @{ name = $name; program = ($rule | Get-NetFirewallApplicationFilter).Program;
           remoteAddresses = $addresses }
    })
    $ruleReceipt | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'egress-rules.json')
    $env:OPENCLAW_UPDATER_PROOF_FIREWALL = '1'
    $env:OPENCLAW_UPDATER_PROOF_PROGRAMS = ConvertTo-Json -InputObject @($programs) -Compress
    $stage = 'fixture-setup'
    $key = [Security.Cryptography.RSA]::Create(2048)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        ('CN=api.github.com, OU=OpenClaw1642-' + $id), $key, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
    $names = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $names.AddDnsName('api.github.com'); $request.CertificateExtensions.Add($names.Build())
    $usages = [Security.Cryptography.OidCollection]::new()
    [void]$usages.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $false))
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddHours(1))
    [IO.File]::WriteAllText((Join-Path $work 'server-key.pem'), $key.ExportPkcs8PrivateKeyPem())
    [IO.File]::WriteAllText((Join-Path $work 'server-cert.pem'), $certificate.ExportCertificatePem())
    $rootCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    Save-CleanupState
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite); $store.Add($rootCertificate)
    $proxyScript = Join-Path $PSScriptRoot 'fixture-proxy.mjs'
    $parameters = @{ FilePath = (Get-Command node).Source; PassThru = $true;
        ArgumentList = @('"' + $proxyScript + '"','"' + $work + '"');
        RedirectStandardOutput = (Join-Path $work 'proxy.stdout'); RedirectStandardError = (Join-Path $work 'proxy.stderr') }
    $proxy = Start-Process @parameters
    Save-CleanupState
    $readyPath = Join-Path $work 'ready.json'; $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path $readyPath)) {
        if ($proxy.HasExited) { throw 'Fixture proxy exited before readiness.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Fixture startup timed out.' }
        Start-Sleep -Milliseconds 100
    }
    $ready = Get-Content $readyPath -Raw | ConvertFrom-Json
    if ($ready.pid -ne $proxy.Id -or -not ([Uri]$ready.proxy).IsLoopback) { throw 'Invalid fixture receipt.' }
    $env:HTTPS_PROXY = $ready.proxy; $env:HTTP_PROXY = $ready.proxy; $env:ALL_PROXY = $ready.proxy
    $env:NO_PROXY = '127.0.0.1,localhost'; $env:OPENCLAW_UPDATER_PROOF_DIR = $work
    $stage = 'production-backend-tests'
    $arguments = @('test', $project, '-c', 'Release', '-r', 'win-x64', '--no-build', '--no-restore',
        '--filter', 'FullyQualifiedName~ProductionUpdaterIntegrationTests', '--results-directory', $evidence,
        '--logger', 'trx;LogFileName=updater-integration.trx', '--blame-hang', '--blame-hang-dump-type', 'none', '--blame-hang-timeout', '2m')
    & dotnet @arguments 2>&1 | Tee-Object -FilePath (Join-Path $evidence 'tests.log')
    $exitCode = $LASTEXITCODE; $trxPath = Join-Path $evidence 'updater-integration.trx'
    if (-not (Test-Path $trxPath)) { throw 'No TRX; no execution claim.' }
    [xml]$trx = Get-Content $trxPath -Raw; $rows = @($trx.TestRun.Results.UnitTestResult)
    if ($exitCode -ne 0 -or $rows.Count -ne 4 -or @($rows | Where-Object outcome -ne 'Passed').Count -ne 0) {
        throw 'All four real-backend cases must pass; no skip/expected-red exemption.'
    }
    & git diff --quiet HEAD -- src docs
    if ($LASTEXITCODE -ne 0) { throw 'Production source changed during proof.' }
    # Global evidence validation includes refusals without a caseId (review regression).
    $stage = 'transport-evidence'
    & node (Join-Path $PSScriptRoot 'verify-requests.mjs') (Join-Path $work 'requests.ndjson')
    if ($LASTEXITCODE -ne 0) { throw 'Unexpected or incomplete transport evidence.' }
    $passed = $true
} catch { $failure = $_.Exception.Message }
finally {
    if ($proxy -and -not $proxy.HasExited) { Stop-Process -Id $proxy.Id -ErrorAction Continue; $proxy.WaitForExit(5000) | Out-Null }
    Get-ChildItem $work -Filter 'case-*.json' -ErrorAction SilentlyContinue | Copy-Item -Destination $evidence
    if (Test-Path (Join-Path $work 'requests.ndjson')) { Copy-Item (Join-Path $work 'requests.ndjson') (Join-Path $evidence 'requests.ndjson') }
    if ($store -and $rootCertificate) {
        try {
            $store.Remove($rootCertificate)
            if ($store.Certificates.Find('FindByThumbprint',$rootCertificate.Thumbprint,$false).Count -ne 0) { throw 'Temporary trust remains.' }
        } catch { $cleanupErrors.Add('certificate cleanup: ' + $_.Exception.Message) }
    }
    if ($store) { $store.Dispose() }; if ($rootCertificate) { $rootCertificate.Dispose() }
    if ($certificate) { $certificate.Dispose() }; if ($key) { $key.Dispose() }
    foreach ($name in $ruleNames) {
        try { Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop }
        catch { $cleanupErrors.Add('firewall cleanup: ' + $_.Exception.Message) }
    }
    foreach ($name in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','NO_PROXY','OPENCLAW_UPDATER_PROOF_FIREWALL')) {
        Remove-Item ('Env:' + $name) -ErrorAction SilentlyContinue
    }
    if ($cleanupErrors.Count -eq 0) { Remove-Item $work -Recurse -Force; Remove-Item $cleanupFile -ErrorAction SilentlyContinue }
    @{ source = $sourceSha; stage = $stage; passed = ($passed -and $cleanupErrors.Count -eq 0);
       failure = $failure; cleanupErrors = @($cleanupErrors.ToArray());
       proof = 'real Updatum HTTP discovery + real backend + selection + blocked selected-asset request';
       nativeCoordinatorOrUI = $false; successfulDownloadOrInstallation = $false } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'result.json')
    Pop-Location
}
if (-not $passed -or $cleanupErrors.Count -gt 0) { throw "Incomplete proof. Stage=$stage; failure=$failure" }
