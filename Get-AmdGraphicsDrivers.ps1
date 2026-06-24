#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest AMD Radeon GPU display drivers (consumer + Radeon Pro) from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\amd-gfx.psd1. Drivers come from
    the catalog (single-source): consumer Radeon RX and workstation Radeon Pro both publish "Advanced Micro
    Devices, Inc. - Display" packages, listed per family because of AMD's current/legacy branch split.
    Selection is highest-version-first (catalog date as tiebreak).

    .NOTES
    SCOPE: POST-BOOT CONVENIENCE drivers only. A GPU cannot serve iSCSI/PXE boot, so nothing here is
    boot-critical — it only provides accelerated display after the OS is running. A bare INF install
    (offline DISM or live pnputil) delivers a fully accelerated driver incl. the OpenGL/Vulkan/OpenCL/D3D
    runtimes; the AMD Software (Adrenalin) app is not included and is out of scope. For Radeon Pro cards the
    catalog serves the base WHQL display driver, NOT the ISV-certified PRO Edition (out of scope).

    .EXAMPLE
    .\Get-AmdGraphicsDrivers.ps1
    .EXAMPLE
    .\Get-AmdGraphicsDrivers.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'amd-gfx.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
