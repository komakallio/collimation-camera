<#
.SYNOPSIS
Runs a built executable from .build-win, with the Swift runtime beside it.

.DESCRIPTION
A development build links against the Swift runtime DLLs, which live in the
toolchain rather than beside the executable, so double-clicking the exe or
starting it from an ordinary shell raises a loader error box. This copies the
runtime DLLs next to the executable once — the same thing the packaged build
does — and then starts the program.

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

# Copy any runtime DLL that is missing or older than the toolchain's copy.
$runtimeBin = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1 |
    ForEach-Object { Join-Path $_.FullName 'usr\bin' }
if ($runtimeBin -and (Test-Path $runtimeBin)) {
    foreach ($dll in Get-ChildItem $runtimeBin -Filter '*.dll') {
        $target = Join-Path $binDirectory $dll.Name
        if (-not (Test-Path $target) -or (Get-Item $target).LastWriteTime -lt $dll.LastWriteTime) {
            Copy-Item $dll.FullName $target -Force
        }
    }
}

# The app looks for Resources beside the executable first, so keep a copy
# there; that is also where a packaged build puts them.
Copy-Item (Join-Path $root 'Resources') $binDirectory -Recurse -Force

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
