<#
.SYNOPSIS
Drives the portable app's window from outside it: minimize, restore, resize.

.DESCRIPTION
Automates the parts of the §9.8 acceptance list that would otherwise need a
person with a mouse, and that are worth re-running after any change to the
main loop: the minimized branch that skips drawing, the swapchain acquire that
fails while minimized, and the layout recomputation on resize.

It reports whether the window kept answering messages at each step, which is
what "did not stall" means, and whether the process survived. It says nothing
about what was drawn — that still needs eyes.

.EXAMPLE
scripts\window-stress-win.ps1
scripts\window-stress-win.ps1 -Directory dist\CollimationCamera-win-x64
#>
param(
    # Directory holding CollimationCamera.exe. Defaults to the debug build.
    [string]$Directory
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $Directory) {
    $Directory = Join-Path $root '.build-win\x86_64-unknown-windows-msvc\debug'
}
$exe = Join-Path $Directory 'CollimationCamera.exe'
if (-not (Test-Path $exe)) { throw "No such executable: $exe" }

. "$PSScriptRoot\stage-win.ps1"
Add-WindowsRuntime -Directory $Directory

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WindowStress {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
}
"@

$process = Start-Process -FilePath $exe -WorkingDirectory $Directory -PassThru

# A debug build loads the vendor SDKs and enumerates before the first frame, so
# wait for the window rather than assuming a fixed startup time.
$handle = [IntPtr]::Zero
for ($waited = 0; $waited -lt 30; $waited++) {
    Start-Sleep -Seconds 1
    $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    if (-not $live) { throw "The app exited during startup. See the log in %LOCALAPPDATA%\Collimation Camera." }
    $handle = $live.MainWindowHandle
    if ($handle -ne [IntPtr]::Zero) { break }
}
if ($handle -eq [IntPtr]::Zero) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "The app started but never opened a window."
}
# One more second so the first frames are through before anything is poked.
Start-Sleep -Seconds 1

function Test-Responding {
    # WM_NULL with SMTO_ABORTIFHUNG: a non-zero return means the message loop
    # answered within the timeout, which is what "not stalled" means here.
    $result = [IntPtr]::Zero
    $answered = [WindowStress]::SendMessageTimeout($handle, 0, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 2000, [ref]$result)
    return $answered -ne [IntPtr]::Zero
}

$failures = 0
function Check([string]$what, [bool]$ok) {
    if ($ok) { Write-Host "ok   $what" } else { Write-Host "FAIL $what"; $script:failures++ }
}

Check 'responds before anything' (Test-Responding)

# SW_MINIMIZE, then ten seconds in the main loop's minimized branch.
[void][WindowStress]::ShowWindow($handle, 6)
Start-Sleep -Seconds 10
Check 'minimized' ([WindowStress]::IsIconic($handle))
Check 'responds while minimized' (Test-Responding)

# SW_RESTORE
[void][WindowStress]::ShowWindow($handle, 9)
Start-Sleep -Seconds 3
Check 'responds after restore' (Test-Responding)

# SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
foreach ($size in @(@(900, 700), @(1600, 1000), @(2400, 1500), @(700, 500))) {
    [void][WindowStress]::SetWindowPos($handle, [IntPtr]::Zero, 0, 0, $size[0], $size[1], 0x0016)
    Start-Sleep -Milliseconds 900
}
Check 'responds after resizing' (Test-Responding)
Check 'still running' (-not $process.HasExited)

Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "$failures check(s) failed."; exit 1 }
Write-Host 'All checks passed. The log is in %LOCALAPPDATA%\Collimation Camera.'
