#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Qualcomm Wi-Fi drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\qualcomm.psd1.
    Covers QCA6390, WCN6855, WCN7850 (modern VEN_17CB ids + marketing-name queries). Bluetooth/
    UART combo-chip entries are excluded by title; selection is highest-version-first with the
    preferred branch as a same-version tiebreak.

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
$config = Import-PowerShellDataFile (Join-Path $csDir 'qualcomm.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
