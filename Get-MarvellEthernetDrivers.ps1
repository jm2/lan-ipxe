#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Marvell/Aquantia 10GbE/5GbE drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\marvell.psd1.
    Covers Marvell's two NIC lines: Aquantia/AQtion PCIe (AQC107, AQC113) + USB AQC111U
    (VID_2ECA&PID_C101), and QLogic-origin FastLinQ 41xxx 10GBASE-T (QL41162/QL41164).
    Selection is highest-version-first (catalog date as tiebreak).

    .EXAMPLE
    .\Get-MarvellEthernetDrivers.ps1
    .EXAMPLE
    .\Get-MarvellEthernetDrivers.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'marvell.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
