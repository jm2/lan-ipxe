#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Intel Ethernet drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\intel-eth.psd1.
    Targets specific Intel Ethernet families (I225/I226, I219/I210, X540/X550/X710, E810, IAVF)
    and downloads the targeted CAB packages for DISM/pnputil injection rather than the
    monolithic Intel ZIP. Selection is highest-version-first (catalog date as tiebreak).

    .EXAMPLE
    .\Get-IntelEthernetDrivers.ps1
    .EXAMPLE
    .\Get-IntelEthernetDrivers.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'intel-eth.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
