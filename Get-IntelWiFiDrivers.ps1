#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Intel PROSet/Wireless Wi-Fi drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\intel-wifi.psd1.
    Intel bundles all supported adapters into unified packages, so two searches (BE200, AX200)
    cover everything from AC 9260 through BE200. Selection is highest-version-first.

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
$config = Import-PowerShellDataFile (Join-Path $csDir 'intel-wifi.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
