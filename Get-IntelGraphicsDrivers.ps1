#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Intel GPU (Arc / Iris Xe / UHD) display drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\intel-gfx.psd1. Intel ships a
    unified DCH display driver, so a single "Intel Corporation - Display" package covers Arc A/B-series,
    Iris Xe, and recent integrated graphics. Selection is highest-version-first (catalog date as tiebreak).

    .NOTES
    SCOPE: POST-BOOT CONVENIENCE drivers only. A GPU cannot serve iSCSI/PXE boot, so nothing here is
    boot-critical — it only provides accelerated display after the OS is running. A bare INF install
    (offline DISM or live pnputil) delivers a fully accelerated driver incl. the OpenGL/Vulkan/OpenCL/D3D
    runtimes; the optional Microsoft Store control-panel app (Intel Graphics Software) is not included and
    is out of scope.

    .EXAMPLE
    .\Get-IntelGraphicsDrivers.ps1
    .EXAMPLE
    .\Get-IntelGraphicsDrivers.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'intel-gfx.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
