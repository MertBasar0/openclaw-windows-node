Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class OC1676Desktop {
 [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
 [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr handle);
 [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint thread);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool GetUserObjectInformation(IntPtr h,int index,StringBuilder output,uint length,out uint needed);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int count);
 public delegate bool Callback(IntPtr hwnd,IntPtr state);
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback,IntPtr state);
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 public sealed class Window {public long Handle;public string Title;}
 public static string Name(IntPtr handle) {
  var text=new StringBuilder(256);uint needed;
  if(!GetUserObjectInformation(handle,2,text,512,out needed)) throw new System.ComponentModel.Win32Exception();
  return text.ToString();
 }
 public static Window[] Windows(uint processId) {
  var rows=new List<Window>();
  EnumWindows((h,s)=>{uint p;GetWindowThreadProcessId(h,out p);if(p==processId && IsWindowVisible(h)){var t=new StringBuilder(512);GetWindowText(h,t,512);rows.Add(new Window{Handle=h.ToInt64(),Title=t.ToString()});}return true;},IntPtr.Zero);
  return rows.ToArray();
 }
}
'@
function Save-RectImage([Drawing.Rectangle]$Rect,[string]$Path) {
 $bitmap=[Drawing.Bitmap]::new($Rect.Width,$Rect.Height)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try {$graphics.CopyFromScreen($Rect.Location,[Drawing.Point]::Empty,$Rect.Size);$bitmap.Save($Path,[Drawing.Imaging.ImageFormat]::Png)} finally {$graphics.Dispose();$bitmap.Dispose()}
}
function Test-HostedDesktop([string]$EvidenceRoot) {
 $inputDesktop=[OC1676Desktop]::OpenInputDesktop(0,$false,1)
 if($inputDesktop -eq [IntPtr]::Zero){throw 'DESKTOP_BLOCKED: cannot open input desktop.'}
 try {
  $inputName=[OC1676Desktop]::Name($inputDesktop)
  $threadName=[OC1676Desktop]::Name([OC1676Desktop]::GetThreadDesktop([OC1676Desktop]::GetCurrentThreadId()))
  if($inputName -cne $threadName -or -not [Environment]::UserInteractive){throw 'DESKTOP_BLOCKED: job is not on the interactive input desktop.'}
  $form=[Windows.Forms.Form]::new();$form.Text='Issue 1676 disposable Actions desktop probe';$form.Width=640;$form.Height=240
  $form.StartPosition='Manual';$form.Location=[Drawing.Point]::new(40,40);$form.TopMost=$true;$form.BackColor=[Drawing.Color]::FromArgb(30,80,140)
  $label=[Windows.Forms.Label]::new();$label.Text='OpenClaw #1676: ephemeral runner, synthetic desktop probe';$label.ForeColor=[Drawing.Color]::White;$label.AutoSize=$true;$label.Location=[Drawing.Point]::new(12,12);$form.Controls.Add($label)
  try {
   $form.Show();$timer=[Diagnostics.Stopwatch]::StartNew();$painted=$false
   do {
    [Windows.Forms.Application]::DoEvents();[void][OC1676Desktop]::SetForegroundWindow($form.Handle)
    $rect=$form.RectangleToScreen($form.ClientRectangle);$image=[Drawing.Bitmap]::new($rect.Width,$rect.Height);$g=[Drawing.Graphics]::FromImage($image)
    try {
     $g.CopyFromScreen($rect.Location,[Drawing.Point]::Empty,$rect.Size)
     $painted=([OC1676Desktop]::GetForegroundWindow() -eq $form.Handle -and $image.GetPixel($image.Width-12,$image.Height-12).ToArgb() -eq $form.BackColor.ToArgb())
     if($painted){$image.Save((Join-Path $EvidenceRoot 'desktop-probe.png'),[Drawing.Imaging.ImageFormat]::Png)}
    } finally {$g.Dispose();$image.Dispose()}
    if(-not $painted){Start-Sleep -Milliseconds 100}
   } until($painted -or $timer.Elapsed.TotalSeconds -ge 15)
   if(-not $painted){throw 'DESKTOP_BLOCKED: synthetic window was not visibly painted and foreground-bound.'}
   [ordered]@{InputDesktop=$inputName;ThreadDesktop=$threadName;Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;ProbeForegroundAndPixelVerified=$true;Screenshot='desktop-probe.png';OS=(Get-CimInstance Win32_OperatingSystem).Caption;Image=$env:ImageOS;ImageVersion=$env:ImageVersion;Windows11Proof=$false}|ConvertTo-Json|Set-Content (Join-Path $EvidenceRoot 'desktop.json') -Encoding utf8
  } finally {$form.Close();$form.Dispose()}
 } finally {[void][OC1676Desktop]::CloseDesktop($inputDesktop)}
}
function Save-CompanionWindows([int]$ProcessId,[string]$EvidenceRoot,[string]$Label) {
 $rows=@();$index=0
 foreach($window in [OC1676Desktop]::Windows([uint32]$ProcessId)) {
  if($index -ge 8){break}
  $hwnd=[IntPtr]$window.Handle;[void][OC1676Desktop]::ShowWindow($hwnd,9);[void][OC1676Desktop]::SetForegroundWindow($hwnd)
  $rect=[OC1676Desktop+Rect]::new()
  if(-not [OC1676Desktop]::GetWindowRect($hwnd,[ref]$rect)){continue}
  $bounds=[Drawing.Rectangle]::FromLTRB($rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
  $bounds=[Drawing.Rectangle]::Intersect($bounds,[Windows.Forms.SystemInformation]::VirtualScreen)
  if($bounds.Width -lt 100 -or $bounds.Height -lt 80){continue}
  Start-Sleep -Milliseconds 200
  $file="$Label-window-$index.png";Save-RectImage $bounds (Join-Path $EvidenceRoot $file)
  $rows+=@{Pid=$ProcessId;Handle=$window.Handle;Title=$window.Title;File=$file};$index++
 }
 ConvertTo-Json -InputObject @($rows) -Depth 5 |Set-Content (Join-Path $EvidenceRoot "$Label-windows.json") -Encoding utf8
}
