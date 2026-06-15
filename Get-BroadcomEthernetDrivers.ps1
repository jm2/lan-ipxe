#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Broadcom NetXtreme-E Ethernet drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\broadcom.psd1.
    Covers the modern NetXtreme-E 10/25GbE controller (BCM57416, VEN_14E4&DEV_16D8), which the
    other scrapers and build_win11pxe.ps1's in-box Broadcom services do NOT cover. Ported from
    the gonefishin branch. Selection is highest-version-first.

    .NOTES
    Verify BCM57416 / DEV_16D8 is actually in your hardware scope before relying on this.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'broadcom.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
