# Reads the pinned SOS dumpdomain text only. Does not inspect or execute a process.
function Get-SosManagedInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Diagnostics)
    $Diagnostics['AssemblyHeaders'] = 0
    $Diagnostics['NamedHeaders'] = 0
    $Diagnostics['UnnamedDynamicHeaders'] = 0
    $Diagnostics['UnnamedNonDynamicHeaders'] = 0
    $Diagnostics['MalformedHeaders'] = 0
    $Diagnostics['DynamicModuleRows'] = 0
    $Diagnostics['UnresolvedModuleRows'] = 0
    $Diagnostics['HeaderShapes'] = @()
    $starts = [regex]::Matches($Text,'(?m)^Assembly:')
    $Diagnostics['AssemblyHeaders'] = $starts.Count
    $Diagnostics['DomainCount'] = [regex]::Matches($Text,'(?m)^Domain[ \t]+\d+:').Count
    # Bounded shapes survive a failed parse without exposing addresses, paths or raw text.
    $headers = [Collections.Generic.List[object]]::new()
    foreach ($start in $starts) {
        $line = ($Text.Substring($start.Index) -split '\r?\n',2)[0]
        $header = [regex]::Match($line,'^Assembly:[ \t]+([0-9a-fA-F`]+)([ \t]+\(Dynamic\))?[ \t]+\[([^\]\r\n]*)\][ \t]*$')
        $shape = 'malformed'
        if (-not $header.Success) { $Diagnostics['MalformedHeaders']++ }
        elseif ($header.Groups[3].Value.Trim()) { $Diagnostics['NamedHeaders']++; $shape = if ($header.Groups[2].Success) { 'named-dynamic' } else { 'named-file-backed' } }
        elseif ($header.Groups[2].Success) { $Diagnostics['UnnamedDynamicHeaders']++; $shape = 'unnamed-dynamic' }
        else { $Diagnostics['UnnamedNonDynamicHeaders']++; $shape = 'unnamed-non-dynamic' }
        if ($Diagnostics['HeaderShapes'].Count -lt 16) { $Diagnostics['HeaderShapes'] += $shape }
        $headers.Add($header)
    }
    if ($Text -match '(?i)\b(?:error|failed|unable|unsupported|interrupted|aborted)\b|could not|not supported|out of memory|unknown module') { throw 'SOS_REPORTED_INCOMPLETE_OR_UNSUPPORTED_DATA' }
    if ($Text -notmatch '(?m)^Domain[ \t]+1:[ \t]+[0-9a-fA-F`]+[ \t]*\r?$' -or $Diagnostics['DomainCount'] -ne 1) { throw 'DEFAULT_DOMAIN_NOT_UNAMBIGUOUSLY_ENUMERATED' }
    if ($starts.Count -eq 0 -or $Diagnostics['MalformedHeaders'] -gt 0 -or $Diagnostics['UnnamedNonDynamicHeaders'] -gt 0) { throw 'UNRESOLVED_ASSEMBLY_ENTRY' }
    $clean = [Collections.Generic.List[object]]::new()
    for ($i=0; $i -lt $starts.Count; $i++) {
        $end = if ($i+1 -lt $starts.Count) { $starts[$i+1].Index } else { $Text.Length }
        $body = $Text.Substring($starts[$i].Index,$end-$starts[$i].Index)
        $header = $headers[$i]
        $isDynamic = $header.Groups[2].Success
        $assemblyName = $header.Groups[3].Value.Trim()
        if ([regex]::Matches($body,'(?m)^[ \t]+Module[ \t]*\r?$').Count -ne 1) { throw 'ASSEMBLY_MODULE_ENUMERATION_MISSING' }
        $rows = [regex]::Matches($body,'(?m)^[ \t]+([0-9a-fA-F`]+)[ \t]+([^\r\n]+)[ \t]*\r?$')
        if ($rows.Count -eq 0) { throw 'ASSEMBLY_MODULE_ENUMERATION_EMPTY' }
        $names = @($rows | ForEach-Object {
            $name = $_.Groups[2].Value.Trim()
            if ($name -ceq 'Dynamic Module' -and $isDynamic) { $Diagnostics['DynamicModuleRows']++; 'Dynamic Module' }
            elseif ($name -match '(?i)\.(?:dll|exe)$') { [IO.Path]::GetFileName($name) }
            else { $Diagnostics['UnresolvedModuleRows']++; throw 'UNRESOLVED_MANAGED_MODULE_NAME' }
        })
        # CoreCLR cannot return a PE path for Reflection.Emit. SOS prints (Dynamic) []
        # and Dynamic Module. This known class cannot be the file-loaded startup hook.
        # Every unnamed non-dynamic entry and every inconsistent dynamic entry still blocks.
        if (-not $assemblyName) {
            if (-not $isDynamic -or @($names | Where-Object { $_ -cne 'Dynamic Module' }).Count -ne 0) { throw 'UNRESOLVED_ASSEMBLY_ENTRY' }
            $assemblyName = '<reflection-emit>'
        }
        $clean.Add([ordered]@{Assembly=[IO.Path]::GetFileName($assemblyName);Dynamic=$isDynamic;Modules=$names})
    }
    $allModules = @($clean | ForEach-Object { $_.Modules })
    if ($allModules -notcontains 'OpenClaw.Tray.WinUI.dll' -or $allModules -notcontains 'System.Private.CoreLib.dll') { throw 'APPLICATION_OR_CORE_MANAGED_MODULE_MISSING' }
    $hookSeen = [bool](@($clean | Where-Object { $_.Assembly -match '(?i)^Issue1676\.StartupHook(?:\.dll)?$' -or $_.Modules -contains 'Issue1676.StartupHook.dll' }).Count)
    [pscustomobject]@{Assemblies=$clean.ToArray();AssemblyCount=$clean.Count;ModuleCount=$allModules.Count;HookPresent=$hookSeen;UnnamedDynamicAssemblyCount=$Diagnostics['UnnamedDynamicHeaders']}
}
