<#
.SYNOPSIS
Puts everything a built executable needs next to it: runtime, SDL3, resources.

.DESCRIPTION
Dot-source this from a script that is about to run a build:

    . "$PSScriptRoot\stage-win.ps1"
    Add-WindowsRuntime -Directory $binDirectory

SwiftPM writes only the executable. The Swift runtime DLLs live in the
toolchain, SDL3.dll comes from Vendor\SDL3 (fetch-sdk.ps1 copies it, but a
`swift package clean` or a deleted output directory takes it away again), and
the app looks for Resources beside the executable first. Staging all three
here means a development build starts the same way the packaged one does.
#>

function Add-WindowsRuntime {
    param(
        # Directory holding the built executable.
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $root = Split-Path -Parent $PSScriptRoot

    # Swift runtime: copy what is missing or older than the toolchain's copy.
    $runtimeBin = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'usr\bin' }
    if ($runtimeBin -and (Test-Path $runtimeBin)) {
        foreach ($dll in Get-ChildItem $runtimeBin -Filter '*.dll') {
            $target = Join-Path $Directory $dll.Name
            if (-not (Test-Path $target) -or (Get-Item $target).LastWriteTime -lt $dll.LastWriteTime) {
                Copy-Item $dll.FullName $target -Force
            }
        }
    }

    # SDL3 is a link-time dependency, so a missing DLL is a loader error box
    # rather than a message in the log.
    $sdl = Join-Path $root 'Vendor\SDL3\lib\x64\SDL3.dll'
    if (Test-Path $sdl) {
        Copy-Item $sdl $Directory -Force
    } else {
        Write-Warning "Missing $sdl. Run scripts\fetch-sdk.ps1 -SDL3Only."
    }

    # Vendor SDKs load at run time, so these are optional.
    foreach ($relative in @(
        'Vendor\PlayerOne\PlayerOneCamera.dll',
        'Vendor\PlayerOne\PlayerOnePW.dll',
        'Vendor\ZWO\ASICamera2.dll'
    )) {
        $path = Join-Path $root $relative
        if (Test-Path $path) { Copy-Item $path $Directory -Force }
    }

    # Fonts and the window icon.
    Copy-Item (Join-Path $root 'Resources') $Directory -Recurse -Force
}
