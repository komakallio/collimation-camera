<#
.SYNOPSIS
Puts MSVC and the Swift toolchain on PATH for the current PowerShell session.

.DESCRIPTION
Dot-source this from a script that needs to build or run Swift code on
Windows:

    . "$PSScriptRoot\win-env.ps1"

SwiftPM looks for a static-library librarian before it does anything else, and
on Windows that is MSVC's link.exe. Without it every build stops at
"toolchain is invalid: could not find CLI tool `link`". Entering the Visual
Studio developer shell fixes that, but it rebuilds PATH from scratch and drops
the Swift toolchain, so this puts Swift back afterwards. Running a built
executable needs the same PATH: the Swift runtime DLLs are not beside it.
#>

function Find-SwiftBin {
    $bin = (Get-Command swift -ErrorAction SilentlyContinue).Source
    if ($bin) { return Split-Path -Parent $bin }
    $toolchain = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Toolchains" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($toolchain) { return (Join-Path $toolchain.FullName 'usr\bin') }
    return $null
}

$swiftBin = Find-SwiftBin
if (-not $swiftBin) {
    throw "No Swift toolchain found. Install it with: winget install --id Swift.Toolchain -e"
}
$runtimeBin = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1 |
    ForEach-Object { Join-Path $_.FullName 'usr\bin' }

# The DevShell module is the only piece actually needed, so look for it
# directly rather than asking vswhere which install to use.
$devShell = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
    "$env:ProgramFiles\Microsoft Visual Studio"
) | Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem $_ -Recurse -Filter 'Microsoft.VisualStudio.DevShell.dll' -ErrorAction SilentlyContinue } |
    Select-Object -First 1

if (-not $devShell) {
    throw "Visual Studio 2022 Build Tools with the MSVC x64 tools are required. Install with: winget install --id Microsoft.VisualStudio.2022.BuildTools -e"
}
# ...\<install>\Common7\Tools\Microsoft.VisualStudio.DevShell.dll
$vsInstall = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $devShell.FullName))

Import-Module $devShell.FullName
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null

# Enter-VsDevShell replaces PATH, so put the Swift toolchain back in front.
$env:Path = ((@($swiftBin, $runtimeBin) | Where-Object { $_ }) -join ';') + ';' + $env:Path

# The Swift installer sets SDKROOT as a user variable, but a shell started
# before the install never inherited it, and without it swiftc cannot find the
# standard library for x86_64-unknown-windows-msvc.
if (-not $env:SDKROOT) {
    $env:SDKROOT = [System.Environment]::GetEnvironmentVariable('SDKROOT', 'User')
}
if (-not $env:SDKROOT) {
    $sdk = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Platforms" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'Windows.platform\Developer\SDKs\Windows.sdk' }
    if ($sdk -and (Test-Path $sdk)) { $env:SDKROOT = $sdk }
}
if (-not $env:SDKROOT) { throw "SDKROOT is not set and no Windows.sdk was found." }
