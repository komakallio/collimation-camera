<#
.SYNOPSIS
Builds the portable app for release and lays out a self-contained zip.

.DESCRIPTION
Produces dist\CollimationCamera-win-x64\ and a zip beside it. The folder runs
on a machine with no Swift toolchain: the Swift runtime DLLs ship next to the
executable, and so do SDL3 and whichever vendor SDKs are in Vendor\.

The release build links as a GUI application, so there is no console behind
the window; everything it would have printed goes to the log file instead
(%LOCALAPPDATA%\Collimation Camera\collimation.log).

Run scripts\fetch-sdk.ps1 first: it downloads SDL3 and the vendor SDKs and
compiles the icon resource the executable carries.

.EXAMPLE
scripts\package-win.ps1
scripts\package-win.ps1 -SkipBuild
#>
param(
    # Package what is already built, for a second run.
    [switch]$SkipBuild,
    [string]$ScratchPath = '.build-win'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\win-env.ps1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$name = 'CollimationCamera-win-x64'
$dist = Join-Path $root "dist\$name"
$binDirectory = Join-Path $root "$ScratchPath\x86_64-unknown-windows-msvc\release"
$exe = Join-Path $binDirectory 'CollimationCamera.exe'

# The icon resource is a build input, not a packaging one: without it the
# executable is already linked with the default icon and rebuilding is the
# only fix.
$res = Join-Path $root 'Resources\CollimationCamera.res'
if (-not (Test-Path $res)) {
    throw "Missing $res. Run scripts\fetch-sdk.ps1 first; it compiles the icon resource."
}

if (-not $SkipBuild) {
    & swift build -c release --product CollimationCamera --scratch-path $ScratchPath
    if ($LASTEXITCODE -ne 0) { throw "The release build failed." }
}
if (-not (Test-Path $exe)) { throw "No such executable: $exe" }

# A GUI-subsystem image is subsystem 2 in the PE optional header. A console
# build would flash a black window on every launch, so this is checked rather
# than assumed.
$bytes = [System.IO.File]::ReadAllBytes($exe)
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
$subsystem = [BitConverter]::ToUInt16($bytes, $peOffset + 4 + 20 + 68)
if ($subsystem -ne 2) {
    throw "The executable is subsystem $subsystem, not 2 (Windows GUI). Check the release linker settings in Package.swift."
}

Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $dist | Out-Null

Copy-Item $exe $dist

# --- Swift runtime ---------------------------------------------------------
# Copy the whole runtime directory rather than a list of names: an unused DLL
# costs a few megabytes, a missing one costs a loader error box on a machine
# with no Swift installed. Static linking is not an option on 6.3.3, whose
# driver links the wrong registrar object for static builds.
$runtimeBin = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1 |
    ForEach-Object { Join-Path $_.FullName 'usr\bin' }
if (-not $runtimeBin) {
    $runtimeBin = Get-ChildItem "$env:ProgramFiles\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'usr\bin' }
}
if (-not $runtimeBin -or -not (Test-Path $runtimeBin)) {
    throw "No Swift runtime directory found under Programs\Swift\Runtimes."
}
$runtimeCount = 0
foreach ($dll in Get-ChildItem $runtimeBin -Filter '*.dll') {
    Copy-Item $dll.FullName $dist -Force
    $runtimeCount++
}
Write-Host "Swift runtime: $runtimeCount DLLs from $runtimeBin"

# --- SDL3 and the vendor SDKs ----------------------------------------------
$sdl = Join-Path $root 'Vendor\SDL3\lib\x64\SDL3.dll'
if (-not (Test-Path $sdl)) { throw "Missing $sdl. Run scripts\fetch-sdk.ps1." }
Copy-Item $sdl $dist

# The camera and wheel SDKs load at run time, so a missing one is a warning:
# the app starts and says that vendor's cameras are unavailable.
$vendorDlls = @(
    'Vendor\PlayerOne\PlayerOneCamera.dll',
    'Vendor\PlayerOne\PlayerOnePW.dll',
    'Vendor\ZWO\ASICamera2.dll'
)
foreach ($relative in $vendorDlls) {
    $path = Join-Path $root $relative
    if (Test-Path $path) {
        Copy-Item $path $dist
    } else {
        Write-Warning "Not packaged: $relative (run scripts\fetch-sdk.ps1 to download it)"
    }
}

# --- Resources and licenses ------------------------------------------------
New-Item -ItemType Directory -Force (Join-Path $dist 'Resources') | Out-Null
Copy-Item (Join-Path $root 'Resources\Fonts') (Join-Path $dist 'Resources') -Recurse -Force
Copy-Item (Join-Path $root 'Resources\AppIcon-256.png') (Join-Path $dist 'Resources') -Force

New-Item -ItemType Directory -Force (Join-Path $dist 'LICENSES') | Out-Null
foreach ($license in Get-ChildItem (Join-Path $root 'LICENSES') -File) {
    # libusb ships only in the macOS packages.
    if ($license.Name -like '*libusb*') { continue }
    Copy-Item $license.FullName (Join-Path $dist 'LICENSES') -Force
}

$readme = @"
Collimation Camera for Windows
==============================

Unzip anywhere and run CollimationCamera.exe. Nothing is installed and
nothing needs to be added to PATH.

Before the first launch
-----------------------

1. Install the camera driver from the vendor, and plug the camera in after
   the driver is installed:
     Player One  https://player-one-astronomy.com/service/software/
     ZWO         https://www.zwoastro.com/downloads/windows
   The DLLs in this folder are the vendor SDKs, not the drivers. Without the
   driver the camera does not appear in the list.
That is the only step. The Swift runtime and the Microsoft C++ runtime
(msvcp140.dll, vcruntime140.dll, and friends, which SDL3.dll and
ASICamera2.dll need) are in this folder, so nothing else has to be
installed. If Windows still reports a missing DLL, install the Microsoft
Visual C++ 2015-2022 Redistributable (x64):
     https://aka.ms/vs/17/release/vc_redist.x64.exe

Windows shows a SmartScreen warning for an unsigned download: choose
"More info", then "Run anyway".

If a camera is not listed
-------------------------

- The vendor driver is installed and the camera is plugged in.
- No other application is holding the camera.
- The log file names every DLL it looked for and why the load failed:
    %LOCALAPPDATA%\Collimation Camera\collimation.log
  The previous run is kept beside it as collimation.log.1.

Settings, calibration, and log
------------------------------

  %LOCALAPPDATA%\Collimation Camera\

Third-party licenses
--------------------

  LICENSES\ in this folder.
"@
Set-Content -Path (Join-Path $dist 'README-windows.txt') -Value $readme -Encoding utf8

# --- Zip -------------------------------------------------------------------
$zip = Join-Path $root "dist\$name.zip"
Remove-Item -Force $zip -ErrorAction SilentlyContinue
Compress-Archive -Path $dist -DestinationPath $zip

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ''
Write-Host "Packaged $dist"
Write-Host "Zipped    $zip ($size MB)"
Write-Host ''
Write-Host 'Test it on a machine without Swift: the window and taskbar icon, the'
Write-Host 'Explorer icon on the exe, and that no console window appears.'
