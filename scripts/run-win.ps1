<#
.SYNOPSIS
Runs a built executable from .build-win, with the Swift runtime beside it.

.DESCRIPTION
A development build gets only the executable from SwiftPM: the Swift runtime
DLLs live in the toolchain, SDL3.dll in Vendor\, and the fonts in Resources\.
Without them Windows raises a loader error box that suspends the process with
no window and no log. This stages all of it beside the executable — what the
packaged build carries — and then starts the program.

Use -Seconds to run it for a fixed time and stop it again, which is how the
render loop is exercised without a person closing the window.

.EXAMPLE
scripts\run-win.ps1 CollimationCamera
scripts\run-win.ps1 CollimationCamera -Seconds 8
scripts\run-win.ps1 CollimationCamera -Configuration release
#>
param(
    [Parameter(Mandatory = $true)][string]$Product,
    [int]$Seconds = 0,
    [string]$ScratchPath = '.build-win',
    # Matches swift build's -c. A debug build runs about five times slower, so
    # anything measuring a rate has to say release here.
    [ValidateSet('debug', 'release')][string]$Configuration = 'debug',
    # Passed to the program itself, for --snapshot and friends.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\win-env.ps1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$binDirectory = Join-Path $root "$ScratchPath\x86_64-unknown-windows-msvc\$Configuration"
$exe = Join-Path $binDirectory "$Product.exe"
if (-not (Test-Path $exe)) { throw "No such executable: $exe" }

. "$PSScriptRoot\stage-win.ps1"
Add-WindowsRuntime -Directory $binDirectory

if ($Seconds -le 0) {
    # Start-Process, not the call operator: the release build is a GUI
    # subsystem image, and PowerShell does not wait for one of those, so `&`
    # returns at once and leaves $LASTEXITCODE empty. That matters because
    # --snapshot's exit status is a check, not decoration. -NoNewWindow keeps a
    # debug build's output inline.
    $process = Start-Process -FilePath $exe -WorkingDirectory $root -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    exit $process.ExitCode
}

$process = Start-Process -FilePath $exe -WorkingDirectory $root -PassThru -ArgumentList $Arguments
Start-Sleep -Seconds $Seconds
if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force
    Write-Output "stopped $Product after $Seconds s"
} else {
    Write-Output "$Product exited on its own with code $($process.ExitCode)"
}
