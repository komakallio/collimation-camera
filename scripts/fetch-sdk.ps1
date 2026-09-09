<#
.SYNOPSIS
Downloads the Windows camera and filter-wheel SDK DLLs the app loads at run time.

.DESCRIPTION
Player One and ZWO ship the DLLs inside zip archives. This script downloads
each archive, extracts the x64 DLL, and puts it in Vendor\. Nothing here is
linked at build time, so a failure only means the app cannot see that vendor's
cameras.

Both vendors also need their own kernel driver installed, which is a separate
download from the vendor software page. Install the drivers before the first
launch.

Override any URL with the matching environment variable if a vendor moves a
file: PLAYERONE_SDK_URL, PLAYERONE_PW_SDK_URL, ZWO_SDK_URL.

SDL3 is fetched too, into Vendor\SDL3. Pass -SDL3Only to skip the vendor
camera SDKs, which is what CI wants.
#>

param(
    # CI only needs SDL3, not the vendor camera SDKs.
    [switch]$SDL3Only
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root 'Vendor'
New-Item -ItemType Directory -Force (Join-Path $vendor 'PlayerOne') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $vendor 'ZWO') | Out-Null

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("collimation-sdk-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $temp | Out-Null

function Get-Archive {
    param([string]$Url, [string]$Destination)

    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -MaximumRedirection 10 -UseBasicParsing
}

function Install-DllFromZip {
    param(
        [string]$Url,
        [string]$ZipName,
        [string]$DllName,
        [string]$TargetDirectory,
        [string]$ManualSource,
        # ZWO ships one archive per platform inside the download, so the DLL is
        # one level further in. Nested archives whose name matches this are
        # expanded before the second look.
        [string]$NestedFilter = '*Windows*.zip'
    )

    $target = Join-Path $TargetDirectory $DllName
    if (Test-Path $target) {
        Write-Host "Already present: $target"
        return
    }

    $zip = Join-Path $temp $ZipName
    try {
        Get-Archive -Url $Url -Destination $zip
    } catch {
        Write-Warning "Could not download $ZipName : $($_.Exception.Message)"
        Write-Warning "Download it by hand from $ManualSource, then copy its lib\x64\$DllName to $TargetDirectory"
        return
    }

    $extracted = Join-Path $temp ([System.IO.Path]::GetFileNameWithoutExtension($ZipName))
    Expand-Archive -Path $zip -DestinationPath $extracted -Force

    function Find-Dll {
        Get-ChildItem -Path $extracted -Recurse -Filter $DllName -ErrorAction SilentlyContinue |
            Sort-Object { if ($_.FullName -match '\\x64\\') { 0 } else { 1 } } |
            Select-Object -First 1
    }

    $found = Find-Dll
    if ($null -eq $found -and $NestedFilter) {
        foreach ($nested in Get-ChildItem -Path $extracted -Recurse -Filter $NestedFilter -ErrorAction SilentlyContinue) {
            Expand-Archive -Path $nested.FullName -DestinationPath (Join-Path $extracted $nested.BaseName) -Force
        }
        $found = Find-Dll
    }
    if ($null -eq $found) {
        Write-Warning "$DllName was not in $ZipName. Extract it by hand from $ManualSource."
        return
    }
    Copy-Item $found.FullName $target -Force
    Write-Host "Installed $target"

    # Keep whatever terms the vendor ships, so a package carries them rather
    # than only the pointer in LICENSES\README.md.
    $licenses = Join-Path $root 'LICENSES'
    $vendorName = Split-Path -Leaf $TargetDirectory
    foreach ($pattern in @('LICENSE*', 'COPYING*', 'EULA*', 'License*')) {
        foreach ($file in Get-ChildItem -Path $extracted -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue) {
            $extension = if ($file.Extension) { $file.Extension } else { '.txt' }
            Copy-Item $file.FullName (Join-Path $licenses "$vendorName-$($file.BaseName)$extension") -Force
            Write-Host "Kept $($file.Name) as $vendorName-$($file.BaseName)$extension"
        }
    }
}

if (-not $SDL3Only) {

# Windows PowerShell 5.1 has no null-coalescing operator, so the overrides are
# spelled out.
$cameraUrl = 'https://player-one-astronomy.com/download/softwares/PlayerOne_Camera_SDK_Windows_V3.10.1.zip'
if ($env:PLAYERONE_SDK_URL) { $cameraUrl = $env:PLAYERONE_SDK_URL }

$wheelUrl = 'https://player-one-astronomy.com/download/softwares/PlayerOne_FilterWheel_SDK_Windows_V1.2.3.zip'
if ($env:PLAYERONE_PW_SDK_URL) { $wheelUrl = $env:PLAYERONE_PW_SDK_URL }

# This link redirects to a short-lived signed URL, so it is followed rather
# than hard-coded.
$zwoUrl = 'https://dl.zwoastro.com/software?app=DeveloperCameraSdk&platform=windows86&region=Overseas'
if ($env:ZWO_SDK_URL) { $zwoUrl = $env:ZWO_SDK_URL }

Install-DllFromZip `
    -Url $cameraUrl `
    -ZipName 'PlayerOne_Camera_SDK_Windows.zip' `
    -DllName 'PlayerOneCamera.dll' `
    -TargetDirectory (Join-Path $vendor 'PlayerOne') `
    -ManualSource 'https://player-one-astronomy.com/service/software/'

Install-DllFromZip `
    -Url $wheelUrl `
    -ZipName 'PlayerOne_FilterWheel_SDK_Windows.zip' `
    -DllName 'PlayerOnePW.dll' `
    -TargetDirectory (Join-Path $vendor 'PlayerOne') `
    -ManualSource 'https://player-one-astronomy.com/service/software/'

Install-DllFromZip `
    -Url $zwoUrl `
    -ZipName 'ASI_Windows_SDK.zip' `
    -DllName 'ASICamera2.dll' `
    -TargetDirectory (Join-Path $vendor 'ZWO') `
    -ManualSource 'https://www.zwoastro.com/software/product-sdk/'

Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Vendor DLLs are in Vendor\PlayerOne and Vendor\ZWO.'
Write-Host 'Install the Player One and ZWO camera drivers before the first launch.'
}

# --- SDL3 ------------------------------------------------------------------
# The portable app links SDL3. The VC package carries the headers, the import
# library, and the DLL; SwiftPM has no post-build hook, so the DLL is copied
# next to both SwiftPM outputs here.

$sdlVersion = '3.4.16'
$sdlUrl = "https://github.com/libsdl-org/SDL/releases/download/release-$sdlVersion/SDL3-devel-$sdlVersion-VC.zip"
if ($env:SDL3_URL) { $sdlUrl = $env:SDL3_URL }

$sdlRoot = Join-Path $vendor 'SDL3'
if (Test-Path (Join-Path $sdlRoot 'lib\x64\SDL3.dll')) {
    Write-Host "Already present: $sdlRoot"
} else {
    $temp2 = Join-Path ([System.IO.Path]::GetTempPath()) ("collimation-sdl-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $temp2 | Out-Null
    $zip = Join-Path $temp2 'SDL3-devel-VC.zip'
    Write-Host "Downloading $sdlUrl"
    Invoke-WebRequest -Uri $sdlUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $temp2 -Force
    $extracted = Get-ChildItem $temp2 -Directory | Where-Object { $_.Name -like 'SDL3-*' } | Select-Object -First 1
    if ($null -eq $extracted) { throw "SDL3 archive layout was not what was expected." }

    New-Item -ItemType Directory -Force (Join-Path $sdlRoot 'include') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $sdlRoot 'lib\x64') | Out-Null
    Copy-Item (Join-Path $extracted.FullName 'include\*') (Join-Path $sdlRoot 'include') -Recurse -Force
    Copy-Item (Join-Path $extracted.FullName 'lib\x64\SDL3.lib') (Join-Path $sdlRoot 'lib\x64') -Force
    Copy-Item (Join-Path $extracted.FullName 'lib\x64\SDL3.dll') (Join-Path $sdlRoot 'lib\x64') -Force
    Remove-Item -Recurse -Force $temp2 -ErrorAction SilentlyContinue
    Write-Host "Installed SDL3 $sdlVersion into $sdlRoot"
}

# SDL3.dll must sit next to the executable. SwiftPM has no post-build hook.
foreach ($config in @('debug', 'release')) {
    foreach ($scratch in @('.build', '.build-win')) {
        $outDir = Join-Path $root "$scratch\x86_64-unknown-windows-msvc\$config"
        if (Test-Path $outDir) {
            Copy-Item (Join-Path $sdlRoot 'lib\x64\SDL3.dll') $outDir -Force
            Write-Host "Copied SDL3.dll to $outDir"
        }
    }
}

Write-Host ''
Write-Host 'SDL3 is in Vendor\SDL3.'

# --- Application icon resource ---------------------------------------------
# The release link embeds Resources\CollimationCamera.res so the executable
# carries its own icon for Explorer, Start, and pinned shortcuts. rc.exe is in
# the Windows SDK, which the developer shell puts on PATH; without it the
# build still works, just with the default executable icon.
$rcSource = Join-Path $root 'Resources\CollimationCamera.rc'
$res = Join-Path $root 'Resources\CollimationCamera.res'
if (Test-Path $rcSource) {
    $rc = Get-Command rc.exe -ErrorAction SilentlyContinue
    if (-not $rc) {
        $sdkBin = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'x64\rc.exe') } |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($sdkBin) { $rc = Join-Path $sdkBin.FullName 'x64\rc.exe' }
    } else {
        $rc = $rc.Source
    }
    if ($rc) {
        & $rc /nologo /fo $res $rcSource | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Compiled $res"
        } else {
            Write-Warning "rc.exe failed; the executable will use the default icon."
        }
    } else {
        Write-Warning "rc.exe not found; the executable will use the default icon."
    }
}
