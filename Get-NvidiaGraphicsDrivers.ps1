#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest NVIDIA GPU display drivers (GeForce + RTX/Quadro) from the Microsoft Update Catalog.

    .DESCRIPTION
    Thin shim over catalogscrape\CatalogScrape.psm1, driven by catalogscrape\nvidia-gfx.psd1. Drivers come
    from the catalog (single-source), NOT nvidia.com: HWID targeting separates the unified consumer GeForce
    package from the professional RTX/Quadro production-branch package. Selection is highest-version-first.

    .NOTES
    SCOPE: POST-BOOT CONVENIENCE drivers only. A GPU cannot serve iSCSI/PXE boot, so nothing here is
    boot-critical — it only provides accelerated display after the OS is running. A bare INF install
    (offline DISM or live pnputil) delivers a fully accelerated driver incl. the OpenGL/Vulkan/OpenCL/D3D
    ICDs and the CUDA/NVENC runtime; the NVIDIA App / Control Panel (Microsoft Store) and the full CUDA
    toolkit are not included and are out of scope. Catalog gives newest-WHQL, not day-0 Game Ready, with no
    GRD-vs-Studio choice; Data Center (Tesla) and vGPU/GRID drivers are out of scope.

    .EXAMPLE
    .\Get-NvidiaGraphicsDrivers.ps1
    .EXAMPLE
    .\Get-NvidiaGraphicsDrivers.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp',
    [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64'
)

$csDir = Join-Path $PSScriptRoot 'catalogscrape'
Import-Module (Join-Path $csDir 'CatalogScrape.psm1') -Force
$config = Import-PowerShellDataFile (Join-Path $csDir 'nvidia-gfx.psd1')
Invoke-DriverScrape -Config $config -Install:$Install -DownloadPath $DownloadPath -Architecture $Architecture
