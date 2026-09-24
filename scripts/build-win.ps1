<#
.SYNOPSIS
Runs a swift command on Windows with both MSVC and the Swift toolchain on PATH.

.EXAMPLE
scripts\build-win.ps1                       # builds and runs core-tests
scripts\build-win.ps1 build --product capture-cli
scripts\build-win.ps1 run core-tests
#>

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\win-env.ps1"

if (-not (Get-Command link -ErrorAction SilentlyContinue)) {
    throw "MSVC link.exe is still not on PATH; SwiftPM will refuse to build."
}

Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not $args -or $args.Count -eq 0) {
    & swift build --product core-tests --scratch-path .build-win
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & swift run --scratch-path .build-win core-tests
    exit $LASTEXITCODE
}

# Everything on Windows shares one scratch path. Without this, a build here
# lands in .build while run-win.ps1 and package-win.ps1 look in .build-win, so
# the documented build-then-run sequence silently runs a stale binary - or
# none at all.
$forwarded = @($args)
if ($forwarded -notcontains '--scratch-path') {
    $forwarded += @('--scratch-path', '.build-win')
}

& swift @forwarded
exit $LASTEXITCODE
