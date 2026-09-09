<#
.SYNOPSIS
Starts the app, closes its window the way a person would, and times the exit.

.DESCRIPTION
The one thing no other script covers. `run-win.ps1 -Seconds` kills the process
and `--snapshot` ends the loop by itself, so for a long time nothing exercised
the path from the window's close button to a clean exit — and it was broken:
the close event set the loop's `running` flag to true instead of false.

Pass means the process is gone within -Wait seconds and the log ends with
`clean exit`. A hang means the loop never saw the close, and a slow exit means
one of the shutdown steps is blocking; the log names it either way.

Note that this closes the SDL window found by its class name, not whatever
`Process.MainWindowHandle` happens to point at, which on this app is a
different window and answers WM_CLOSE by doing nothing.

.EXAMPLE
scripts\quit-win.ps1
scripts\quit-win.ps1 -Configuration release -Settle 15
#>
param(
    [string]$ScratchPath = '.build-win',
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    # Seconds to let it run before closing, so a camera is connected and the
    # capture thread is inside the vendor SDK when the close arrives.
    [int]$Settle = 10,
    [int]$Wait = 15
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\win-env.ps1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$binDirectory = Join-Path $root "$ScratchPath\x86_64-unknown-windows-msvc\$Configuration"
$exe = Join-Path $binDirectory 'CollimationCamera.exe'
if (-not (Test-Path $exe)) { throw "No such executable: $exe" }

. "$PSScriptRoot\stage-win.ps1"
Add-WindowsRuntime -Directory $binDirectory

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class CollimationQuitTest {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static IntPtr FindSDLWindow(uint target) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == target && IsWindowVisible(h)) {
        var c = new StringBuilder(256); GetClassNameW(h, c, 256);
        if (c.ToString() == "SDL_app") { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

$process = Start-Process -FilePath $exe -WorkingDirectory $root -PassThru
Start-Sleep -Seconds $Settle

$handle = [CollimationQuitTest]::FindSDLWindow([uint32]$process.Id)
if ($handle -eq [IntPtr]::Zero) {
    Stop-Process -Id $process.Id -Force
    throw 'The app has no visible SDL window; it never got as far as the main loop.'
}

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
[void][CollimationQuitTest]::PostMessage($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
$exited = $process.WaitForExit($Wait * 1000)
$stopwatch.Stop()
$seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

if (-not $exited) {
    Stop-Process -Id $process.Id -Force
    throw "Still running $Wait s after the window was closed. See the log."
}

Write-Output "Quit in $seconds s (exit code $($process.ExitCode))."
$log = Join-Path $env:LOCALAPPDATA 'Collimation Camera\collimation.log'
if (Test-Path $log) { Get-Content $log -Tail 6 }
