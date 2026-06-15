#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Realtek NetAdapterCx (11.x) drivers for modern PCIe and USB Realtek
    NIC families from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\realtek.psd1.
    Covers PCIe (RTL8125/8126/8127/8168) and USB (RTL8153/8156/8157/8159).

    Selection is by highest parsed driver [version] (with catalog publish date as a tiebreak),
    NOT by the catalog "Version Date" field: many Realtek USB packages carry a stale 2016/2018
    INF date, so sorting by date would pick an older build than the version string actually
    indicates (e.g. RTL8159 11.19.602.2025 vs the 2018-dated 11.19.20.602).

    .EXAMPLE
    .\Get-RealtekEthernetDrivers.ps1
    .EXAMPLE
    .\Get-RealtekEthernetDrivers.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'realtek.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
