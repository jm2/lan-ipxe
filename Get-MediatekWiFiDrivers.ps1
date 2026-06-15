#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest MediaTek Wi-Fi drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\mediatek.psd1.
    Covers MT7921/MT7921K/MT7922/MT7925/MT7927 (native ARM64 included via -Architecture).
    Bluetooth/UART combo-chip entries are excluded by title; selection is highest-version-first,
    so the current 26.30 branch wins for MT7925/MT7927.

    .NOTES
    SCOPE: POST-BOOT CONVENIENCE drivers only. Wi-Fi cannot serve iSCSI/PXE boot, so nothing
    here is boot-critical — it only restores wireless connectivity after the OS is running.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'mediatek.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
