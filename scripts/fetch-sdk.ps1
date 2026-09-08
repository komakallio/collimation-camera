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

SDL3 and the Windows icon resource arrive with milestone 3; they are not
fetched here yet.
#>

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
        [string]$ManualSource
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
    $found = Get-ChildItem -Path $extracted -Recurse -Filter $DllName |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Select-Object -First 1
    if ($null -eq $found) {
        $found = Get-ChildItem -Path $extracted -Recurse -Filter $DllName | Select-Object -First 1
    }
    if ($null -eq $found) {
        Write-Warning "$DllName was not in $ZipName. Extract it by hand from $ManualSource."
        return
    }
    Copy-Item $found.FullName $target -Force
    Write-Host "Installed $target"
}

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
