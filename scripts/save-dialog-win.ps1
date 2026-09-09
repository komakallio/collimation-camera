<#
.SYNOPSIS
Drives Save TIFF end to end: opens the native dialog, commits a file name, and
checks that a file came out and the app survived.

.DESCRIPTION
The save dialog is the only part of the app that runs a Swift callback on a
thread SDL owns, and that is exactly where it broke: the callback was a closure
written inside the @MainActor PortableUIHost, so it carried that isolation, and
Swift's isolation check at its entry is dispatch_assert_queue against the main
queue. On SDL's dialog thread the assertion fails and libdispatch answers with
ud2, so every Save TIFF killed the app with STATUS_ILLEGAL_INSTRUCTION
(0xC000001D) before a single line of the callback ran. It looked like a hang
because the freeze a user sees is Windows Error Reporting collecting the crash.

Nothing else covers this. No unit test can see an isolation check, --snapshot
never opens a dialog, and the crash leaves no log line because it happens
before the first statement. Run this after touching Dialogs.swift, the main
loop, or anything about actor isolation in the portable app.

Pass: "SAVED" plus a file whose size matches the ROI, and a process that is
still alive and not hung.

.EXAMPLE
scripts\save-dialog-win.ps1
scripts\save-dialog-win.ps1 -Configuration debug -Settle 20
#>
param(
    [string]$ScratchPath = '.build-win',
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    # Seconds to let the app connect and start tracking before saving.
    [int]$Settle = 14,
    [string]$SaveAs = "$env:TEMP\collimation-save-dialog-test.tif"
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
public class CollimationSaveDialogTest {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  // Windows refuses SetForegroundWindow to a process that does not already own
  // the foreground, and refuses it silently: it returns false and the
  // keystrokes go to whatever the user was using. Attaching this thread's
  // input queue to the foreground window's thread lifts that restriction for
  // the length of the call, which is the standard way to drive another app.
  public static bool Focus(IntPtr h) {
    for (int i = 0; i < 10; i++) {
      if (GetForegroundWindow() == h) return true;
      IntPtr fg = GetForegroundWindow();
      uint ignored;
      uint fgThread = GetWindowThreadProcessId(fg, out ignored);
      uint me = GetCurrentThreadId();
      bool attached = fgThread != me && AttachThreadInput(me, fgThread, true);
      ShowWindow(h, 9);            // SW_RESTORE
      BringWindowToTop(h);
      SetForegroundWindow(h);
      if (attached) AttachThreadInput(me, fgThread, false);
      System.Threading.Thread.Sleep(250);
    }
    return GetForegroundWindow() == h;
  }
  public static IntPtr Find(uint target, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == target && IsWindowVisible(h)) {
        var c = new StringBuilder(256); GetClassNameW(h, c, 256);
        if (c.ToString() == cls) { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

if (Test-Path $SaveAs) { Remove-Item $SaveAs -Force }

$process = Start-Process -FilePath $exe -WorkingDirectory $root -PassThru
try {
    Start-Sleep -Seconds $Settle
    if ($process.HasExited) { throw "The app exited during startup with $($process.ExitCode)." }

    $window = [CollimationSaveDialogTest]::Find([uint32]$process.Id, 'SDL_app')
    if ($window -eq [IntPtr]::Zero) { throw 'The app has no visible SDL window.' }

    # A posted WM_KEYDOWN is not enough: SDL only reports key events for a
    # window that holds keyboard focus, so the shortcut has to arrive as real
    # input, and that means taking the foreground. Windows may refuse while
    # somebody is using the machine, and that is not a product failure.
    if (-not [CollimationSaveDialogTest]::Focus($window)) {
        Write-Output 'SKIPPED: Windows would not give the app the foreground. This drives the real keyboard, so it needs an idle desktop.'
        exit 2
    }

    $dialog = [IntPtr]::Zero
    for ($try = 1; $try -le 3 -and $dialog -eq [IntPtr]::Zero; $try++) {
        [void][CollimationSaveDialogTest]::Focus($window)
        Start-Sleep -Milliseconds 400
        # Ctrl+S is the Save TIFF shortcut.
        [CollimationSaveDialogTest]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
        [CollimationSaveDialogTest]::keybd_event(0x53, 0, 0, [IntPtr]::Zero)
        [CollimationSaveDialogTest]::keybd_event(0x53, 0, 2, [IntPtr]::Zero)
        [CollimationSaveDialogTest]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
        Start-Sleep -Seconds 3
        # The common item dialog is a plain #32770, on a thread of SDL's own.
        $dialog = [CollimationSaveDialogTest]::Find([uint32]$process.Id, '#32770')
    }
    if ($dialog -eq [IntPtr]::Zero) {
        throw 'No save dialog appeared after three tries. Either the shortcut did not reach the window or Save TIFF was disabled because no frame had arrived - try a longer -Settle.'
    }
    if (-not [CollimationSaveDialogTest]::Focus($dialog)) { throw 'The save dialog would not take the foreground.' }
    Start-Sleep -Milliseconds 500

    $shell = New-Object -ComObject WScript.Shell
    $shell.SendKeys('^a')
    Start-Sleep -Milliseconds 300
    $shell.SendKeys($SaveAs)
    Start-Sleep -Milliseconds 800
    $shell.SendKeys('{ENTER}')

    for ($i = 0; $i -lt 20 -and -not $process.HasExited; $i++) { Start-Sleep -Milliseconds 500 }

    if ($process.HasExited) {
        throw "The app died committing the save, exit code 0x$('{0:X8}' -f $process.ExitCode). 0xC000001D is an illegal instruction, which for this app means a libdispatch assertion - read the comment on portableDialogCallback."
    }
    if ([CollimationSaveDialogTest]::IsHungAppWindow($window)) {
        throw 'The app survived but its window is hung: the main loop stopped pumping after the save.'
    }
    if (-not (Test-Path $SaveAs)) { throw "No file at $SaveAs." }

    $size = (Get-Item $SaveAs).Length
    Write-Output "SAVED $SaveAs - $size bytes - app alive and responsive."
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}

$log = Join-Path $env:LOCALAPPDATA 'Collimation Camera\collimation.log'
if (Test-Path $log) { Get-Content $log -Encoding UTF8 -Tail 4 }
