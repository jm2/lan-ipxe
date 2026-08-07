#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest MediaTek Wi-Fi drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\mediatek.psd1.
    Two family entries (one unified INF per driver generation):
      WiFi6 — MT7921/MT7921K(RZ608)/MT7922(RZ616), x64 branch 3.5 -> 25.40 -> 26.40
      WiFi7 — MT7925(RZ717)/MT7927(RZ738/MT6639), x64 on 26.40; ARM64 on its own 6.4 branch
    Bluetooth/UART combo-chip entries are excluded by title; candidates are hwid-verified
    (catalog record pre-download, extracted INF post-download); selection is
    highest-version-first per family+arch.

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
