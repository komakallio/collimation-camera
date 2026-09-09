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
#>
param(
    [Parameter(Mandatory = $true)][string]$Product,
    [int]$Seconds = 0,
    [string]$ScratchPath = '.build-win'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\win-env.ps1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$binDirectory = Join-Path $root "$ScratchPath\x86_64-unknown-windows-msvc\debug"
$exe = Join-Path $binDirectory "$Product.exe"
if (-not (Test-Path $exe)) { throw "No such executable: $exe" }

. "$PSScriptRoot\stage-win.ps1"
Add-WindowsRuntime -Directory $binDirectory

if ($Seconds -le 0) {
    & $exe
    exit $LASTEXITCODE
}

$process = Start-Process -FilePath $exe -WorkingDirectory $root -PassThru
Start-Sleep -Seconds $Seconds
if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force
    Write-Output "stopped $Product after $Seconds s"
} else {
    Write-Output "$Product exited on its own with code $($process.ExitCode)"
}
