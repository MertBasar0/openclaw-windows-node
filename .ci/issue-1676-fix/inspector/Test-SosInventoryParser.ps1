[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Parse-SosInventory.ps1"
$base=@'
Domain 1:           000001a944a4e790
LowFrequencyHeap:   0000000000000000
HighFrequencyHeap:  0000000000000000
StubHeap:           0000000000000000
Stage:              OPEN
Name:               clrhost
Assembly:           000001a944a6e3e0 [C:\fixture\System.Private.CoreLib.dll]
  Module
  00007ffad3dc4000    C:\fixture\System.Private.CoreLib.dll

Assembly:           000001a944c2b620 [C:\fixture\OpenClaw.Tray.WinUI.dll]
  Module
  00007ffad3dc6000    C:\fixture\OpenClaw.Tray.WinUI.dll

'@
$dynamic=@'
Assembly:           000001a944d10290 (Dynamic) []
  Module
  000001a944d10200    Dynamic Module

'@
$hook=@'
Assembly:           000001a944d18290 [C:\fixture\Issue1676.StartupHook.dll]
  Module
  00007ffad3dc8000    C:\fixture\Issue1676.StartupHook.dll

'@
$oldRegex='(?ms)^Assembly:\s+([0-9a-fA-F`]+)(\s+\(Dynamic\))?\s+\[([^\]\r\n]+)\]\s*\r?\n(.*?)(?=^Assembly:|^Domain\s+\d+:|^Shared Domain:|^System Domain:|\z)'
$withDynamic=$base+"`n"+$dynamic
$oldHeaders=[regex]::Matches($withDynamic,'(?m)^Assembly:').Count
$oldMatched=[regex]::Matches($withDynamic,$oldRegex).Count
if ($oldHeaders -ne 3 -or $oldMatched -ne 2) { throw 'Old parser did not reproduce the definite source-format failure.' }
$cases=@(
 @{Name='named LF';Text=$base;Count=2;Dynamic=0;Hook=$false},
 @{Name='named CRLF';Text=$base.Replace("`n","`r`n");Count=2;Dynamic=0;Hook=$false},
 @{Name='DAC Reflection.Emit LF';Text=$withDynamic;Count=3;Dynamic=1;Hook=$false},
 @{Name='DAC Reflection.Emit CRLF';Text=$withDynamic.Replace("`n","`r`n");Count=3;Dynamic=1;Hook=$false},
 @{Name='hook present remains detected';Text=($withDynamic+"`n"+$hook);Count=4;Dynamic=1;Hook=$true},
 @{Name='unnamed non-dynamic remains blocked';Text=($base+"`n"+$dynamic.Replace(' (Dynamic)',''));Error='UNRESOLVED_ASSEMBLY_ENTRY'},
 @{Name='unnamed dynamic with file-backed module remains blocked';Text=($base+"`n"+$dynamic.Replace('Dynamic Module','C:\fixture\Issue1676.StartupHook.dll'));Error='UNRESOLVED_ASSEMBLY_ENTRY'},
 @{Name='missing bracket remains blocked';Text=$base.Replace('[C:\fixture\OpenClaw.Tray.WinUI.dll]','C:\fixture\OpenClaw.Tray.WinUI.dll');Error='UNRESOLVED_ASSEMBLY_ENTRY'},
 @{Name='missing module table remains blocked';Text=$base.Replace("  Module`n",'');Error='ASSEMBLY_MODULE_ENUMERATION_MISSING'},
 @{Name='truncated module remains blocked';Text=$base.Replace('    C:\fixture\OpenClaw.Tray.WinUI.dll','');Error='ASSEMBLY_MODULE_ENUMERATION_EMPTY'},
 @{Name='unknown module remains blocked';Text=$base.Replace('    C:\fixture\OpenClaw.Tray.WinUI.dll','    Unknown Module');Error='SOS_REPORTED_INCOMPLETE_OR_UNSUPPORTED_DATA'},
 @{Name='application missing remains blocked';Text=$base.Replace('OpenClaw.Tray.WinUI.dll','Other.dll');Error='APPLICATION_OR_CORE_MANAGED_MODULE_MISSING'}
)
$results=@()
foreach ($case in $cases) {
 $diagnostic=[ordered]@{}
 $observedError=$null;$result=$null
 try { $result=Get-SosManagedInventory -Text $case.Text -Diagnostics $diagnostic } catch { $observedError=$_.Exception.Message }
 if ($case.ContainsKey('Error')) {
  if ($observedError -cne $case.Error) { throw "Parser case '$($case.Name)' expected '$($case.Error)', observed '$observedError'." }
 } else {
  if ($observedError) { throw "Parser case '$($case.Name)' unexpectedly failed: $observedError" }
  if ($result.AssemblyCount -ne $case.Count -or $result.UnnamedDynamicAssemblyCount -ne $case.Dynamic -or $result.HookPresent -ne $case.Hook) { throw "Parser case '$($case.Name)' mismatched expected inventory." }
 }
 if ($diagnostic.HeaderShapes.Count -gt 16 -or ($diagnostic | ConvertTo-Json -Depth 8) -match 'C:\\fixture|000001a944') { throw 'Parser diagnostics leaked raw paths/addresses.' }
 $results += [ordered]@{Name=$case.Name;Result='PASS';ExpectedFailure=$case.ContainsKey('Error')}
}
[ordered]@{OldParser=[ordered]@{Headers=$oldHeaders;Matched=$oldMatched;Result='SOURCE_FORMAT_REGRESSION_REPRODUCED'};Controls=$results;NativeProof=$false}|ConvertTo-Json -Depth 8
