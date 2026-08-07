#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest MediaTek Wi-Fi drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\mediatek.psd1.
    Covers MT7921/MT7921K(RZ608)/MT7922(RZ616)/MT7925(RZ717)/MT7927(RZ738/MT6639).
    Bluetooth/UART combo-chip entries are excluded by title; selection is highest-version-first
    per Key+Arch group: x64 picks the 26.40 branch for MT7925/MT7927, while -Architecture
    arm64/all picks the ARM64-only 6.4 branch (first shipped 6.4.0.3037, May 2026 — one
    package covers both chips and the RZ rebrands).

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
