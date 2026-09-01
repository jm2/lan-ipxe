<#
.SYNOPSIS
Idempotent Windows 11 workstation setup.

.DESCRIPTION
Replaces the former comtrya manifest win11_workstation.yaml (comtrya is
unmaintained upstream). Run from an elevated PowerShell; Windows PowerShell
5.1 is enough (PowerShell 7 is one of the packages it installs).

Safe to re-run: every step reconciles state first. Ordinary converged packages
are left alone; selected fast-moving developer tools still receive a WinGet
upgrade check.

  1. OpenSSH Server via enable-openssh-win11.ps1. Every run reconciles the
     capability, sshd state/start type, firewall rule, and DefaultShell.
  2. Hyper-V via the supported Windows optional feature - only with -HyperV.
     Windows 11 Pro/Enterprise (not Home) and compatible hardware are required.
  3. The winget package set. One `winget export` snapshot of what is
     installed decides what is missing. Ordinary installed packages are left
     alone, while the actively developed AI CLIs/editors are checked for
     updates every run. The legacy Antigravity IDE and VSCodium packages are
     removed in favor of Antigravity 2.0 and Microsoft VS Code. "Already
     installed" and "reboot required" results count as success; any other
     failure is reported at the end (exit code 1) without stopping the run, so
     one broken installer never blocks the rest.

.PARAMETER HyperV
Also enable the supported Hyper-V optional feature. Windows 11 Home is rejected;
supported editions generally need a reboot afterwards.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1 -HyperV
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$HyperV
)

$ErrorActionPreference = 'Stop'
# winget's non-zero exit codes are interpreted by hand below; keep
# PowerShell 7.4+ from turning them into terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

#--- Config -----------------------------------------------------------------
$OpenSshDefaultShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

$WingetPackages = @(
    '7zip.7zip'
    'Anthropic.ClaudeCode'
    'Apple.iTunes'
    # 'Blizzard.BattleNet'            # broken: interactive installer
    'ExtremeTuxRacer.ExtremeTuxRacer'
    'GIMP.GIMP.3'
    'Git.Git'
    'GitHub.GitHubDesktop'
    'GitHub.cli'
    'GOG.Galaxy'
    'GoLang.Go'
    'Google.AndroidStudio'
    'Google.Antigravity'
    'Google.AntigravityCLI'
    'Google.Chrome'
    'Google.GoogleDrive'
    'Google.PlatformTools'
    'GuinpinSoft.MakeMKV'
    'Inkscape.Inkscape'
    'Jigsaw.OutlineManager'
    # 'Jigsaw.Outline'                # not present upstream
    'jm2.Tributary'
    'Kitware.CMake'
    'LLVM.LLVM'
    'MediaArea.MediaInfo.GUI'
    'Meld.Meld'
    'Microsoft.PowerShell'
    'Microsoft.VisualStudio.Community'
    'Microsoft.VisualStudioCode'
    'Microsoft.WindowsTerminal'
    'Microsoft.WingetCreate'
    'Microsoft.WSL'
    'Mozilla.Firefox'
    'mpv.net'
    # 'MSYS2.MSYS2'                   # not handled cleanly
    'Ninja-build.Ninja'
    'Ookla.Speedtest.CLI'
    'Ookla.Speedtest.Desktop'
    'OpenAI.Codex'
    'Plex.Plex'
    'PuTTY.PuTTY'
    'Python.Python.3.14'
    'Rufus.Rufus'
    'Rustlang.Rustup'
    'Silicondust.HDHomeRun'
    'SST.opencode'
    'SuperTux.SuperTux'
    'SuperTuxKart.SuperTuxKart'
    'Tailscale.Tailscale'
    'Unigine.HeavenBenchmark'
    'Valve.Steam'
    'Ventoy.Ventoy'
    'VideoLAN.VLC'
    'WinDirStat.WinDirStat'
    'WinSCP.WinSCP'
    'WiresharkFoundation.Wireshark'
    'Xming.Xming'
    'ZedIndustries.Zed'
    # x64-only candidate, never enabled in the manifest:
    # 'Intel.IntelDriverAndSupportAssistant'
)
$WingetAlwaysUpgradePackages = @(
    'Anthropic.ClaudeCode'
    'Google.Antigravity'
    'Google.AntigravityCLI'
    'OpenAI.Codex'
    'SST.opencode'
    'ZedIndustries.Zed'
)
$WingetLegacyPackages = @(
    'Google.AntigravityIDE'
    'VSCodium.VSCodium'
)

# winget exit codes (AppInstallerErrors.h). PowerShell parses these hex
# literals as the negative Int32 values $LASTEXITCODE actually carries.
$WingetOkCodes = @{
    0          = 'installed'
    0x8A15002B = 'already current (no applicable update)'      # UPDATE_NOT_APPLICABLE
    0x8A150061 = 'already installed'                           # PACKAGE_ALREADY_INSTALLED
    0x8A15010D = 'already installed'                           # INSTALL_ALREADY_INSTALLED
    0x8A150109 = 'installed - reboot required to finish'       # INSTALL_REBOOT_REQUIRED_TO_FINISH
    0x8A15010B = 'installed - the installer initiated a reboot' # INSTALL_REBOOT_INITIATED
}
$WingetRebootCodes = @(0x8A150109, 0x8A15010A, 0x8A15010B)
# Not installed yet, but only a reboot stands in the way: re-run afterwards
$WingetDeferredCodes = @{
    0x8A15010A = 'a reboot is required before this can be installed'  # INSTALL_REBOOT_REQUIRED_FOR_INSTALL
}
$WingetRemoveOkCodes = @{
    0          = 'removed'
    0x8A150014 = 'already absent'                            # NO_APPLICATIONS_FOUND
    0x8A150109 = 'removed - reboot required to finish'      # INSTALL_REBOOT_REQUIRED_TO_FINISH
    0x8A15010B = 'removed - the uninstaller initiated a reboot' # INSTALL_REBOOT_INITIATED
}
$WingetExportOkCodes = @(0, 0x8A150035) # success, or NOT_ALL_PACKAGES_FOUND

#--- Helpers ----------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" }

# Ids of every installed package winget can match to a source. One
# `winget export` is far cheaper than a `winget list` per package, and its
# JSON is exact where the list's table output is truncated.
function Get-WingetInventory {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("winget-export-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        # 0x8A150035 means some unrelated installed applications could not be
        # matched to this source; the matched winget inventory is still valid.
        & winget export -o $tmp --source winget --accept-source-agreements --disable-interactivity | Out-Null
        $code = $LASTEXITCODE
        if ($WingetExportOkCodes -notcontains $code) {
            throw ("winget export failed with 0x{0:X8} ({0})" -f $code)
        }
        if (-not (Test-Path -LiteralPath $tmp)) {
            throw "winget export produced no file (exit code $code)"
        }
        try {
            $snapshot = Get-Content -Raw -LiteralPath $tmp | ConvertFrom-Json
        }
        catch {
            throw "winget export produced invalid JSON: $($_.Exception.Message)"
        }
        if ($snapshot.PSObject.Properties.Name -notcontains 'Sources') {
            throw 'winget export JSON has no Sources property'
        }
        $sources = @($snapshot.Sources)
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($source in $sources) {
            if ($source.PSObject.Properties.Name -notcontains 'Packages') {
                throw 'winget export JSON contains a source without a Packages collection'
            }
            $packages = @($source.Packages)
            if ($packages.Count -eq 0) {
                throw 'winget export JSON contains an empty Packages collection'
            }
            foreach ($package in $packages) {
                if ($package.PSObject.Properties.Name -notcontains 'PackageIdentifier' -or
                    [string]::IsNullOrWhiteSpace([string]$package.PackageIdentifier)) {
                    throw 'winget export JSON contains a package without a PackageIdentifier'
                }
                $ids.Add([string]$package.PackageIdentifier)
            }
        }
        return $ids
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Reconcile the package set from a single inventory snapshot. Selected current
# AI CLIs/editors move quickly, so installed copies are upgraded instead of
# being treated as converged. Superseded packages are removed before their
# supported replacements are installed/upgraded.
function Invoke-WingetPackageSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InstalledIds,

        [Parameter(Mandatory = $true)]
        [string[]]$DesiredIds,

        [string[]]$AlwaysUpgradeIds = @(),

        [string[]]$LegacyIds = @()
    )

    $present = @()
    $missing = @()
    $upgrade = @()
    foreach ($id in $DesiredIds) {
        if ($InstalledIds -contains $id) {
            if ($AlwaysUpgradeIds -contains $id) {
                $upgrade += $id
            }
            else {
                $present += $id
            }
        }
        else {
            $missing += $id
        }
    }

    Write-Note "$($present.Count) ordinary present, $($missing.Count) missing, $($upgrade.Count) checking for updates"

    $removedLegacy = @()
    $installedNow = @()
    $updatedOrCurrent = @()
    $deferred = @()
    $failed = @()

    foreach ($id in $LegacyIds) {
        if ($InstalledIds -notcontains $id) { continue }

        Write-Note "removing legacy $id"
        & winget uninstall --id $id --exact --source winget --silent --accept-source-agreements --disable-interactivity | Out-Host
        $code = $LASTEXITCODE
        if ($WingetRebootCodes -contains $code) { $script:RebootNeeded = $true }
        if ($WingetRemoveOkCodes.ContainsKey($code)) {
            $removedLegacy += $id
            Write-Note "$id`: $($WingetRemoveOkCodes[$code])"
        }
        elseif ($WingetDeferredCodes.ContainsKey($code)) {
            $deferred += "uninstall $id"
            Write-Warning "$id`: $($WingetDeferredCodes[$code])"
        }
        else {
            $failed += "uninstall $id"
            Write-Warning ("{0}: winget uninstall exited with 0x{1:X8} ({1})" -f $id, $code)
        }
    }

    foreach ($id in $missing) {
        Write-Note "installing $id"
        & winget install --id $id --exact --source winget --no-upgrade --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        $code = $LASTEXITCODE
        if ($WingetRebootCodes -contains $code) { $script:RebootNeeded = $true }
        if ($WingetOkCodes.ContainsKey($code)) {
            $installedNow += $id
            Write-Note "$id`: $($WingetOkCodes[$code])"
        }
        elseif ($WingetDeferredCodes.ContainsKey($code)) {
            $deferred += "install $id"
            Write-Warning "$id`: $($WingetDeferredCodes[$code])"
        }
        else {
            $failed += "install $id"
            Write-Warning ("{0}: winget install exited with 0x{1:X8} ({1})" -f $id, $code)
        }
    }

    foreach ($id in $upgrade) {
        Write-Note "updating $id"
        & winget upgrade --id $id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        $code = $LASTEXITCODE
        if ($WingetRebootCodes -contains $code) { $script:RebootNeeded = $true }
        if ($WingetOkCodes.ContainsKey($code)) {
            $updatedOrCurrent += $id
            Write-Note "$id`: $($WingetOkCodes[$code])"
        }
        elseif ($WingetDeferredCodes.ContainsKey($code)) {
            $deferred += "upgrade $id"
            Write-Warning "$id`: $($WingetDeferredCodes[$code])"
        }
        else {
            $failed += "upgrade $id"
            Write-Warning ("{0}: winget upgrade exited with 0x{1:X8} ({1})" -f $id, $code)
        }
    }

    return [pscustomobject]@{
        Present = @($present)
        Installed = @($installedNow)
        UpdatedOrCurrent = @($updatedOrCurrent)
        RemovedLegacy = @($removedLegacy)
        Deferred = @($deferred)
        Failed = @($failed)
    }
}

#--- Preflight --------------------------------------------------------------
$script:RebootNeeded = $false
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install/update "App Installer" from the Microsoft Store, then re-run.'
}

#--- 1. OpenSSH Server ------------------------------------------------------
Write-Step 'OpenSSH Server'
& (Join-Path $PSScriptRoot 'enable-openssh-win11.ps1')
$defaultShell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell
if ($defaultShell -ne $OpenSshDefaultShell) {
    throw 'OpenSSH helper returned without converging DefaultShell'
}
Write-Note 'capability, sshd, firewall, and DefaultShell reconciled'

#--- 2. Hyper-V (opt-in) ----------------------------------------------------
if ($HyperV) {
    Write-Step 'Hyper-V (supported Windows optional feature)'
    $state = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue).State
    if ($state -eq 'Enabled') {
        Write-Note 'enabled'
    }
    elseif ($state -eq 'EnablePending') {
        $script:RebootNeeded = $true
        Write-Note 'enable pending - reboot required'
    }
    else {
        $hyperVResult = @(& (Join-Path $PSScriptRoot 'enable-hyperv-win11.ps1') -PassThru)
        if ($hyperVResult.Count -ne 1) {
            throw 'Hyper-V helper did not return exactly one status result'
        }
        $newState = [string]$hyperVResult[0].State
        if ($newState -ne 'Enabled' -and $newState -ne 'EnablePending') {
            throw "Hyper-V helper returned with unexpected feature state: $newState"
        }
        if ([bool]$hyperVResult[0].RestartNeeded -or $newState -eq 'EnablePending') {
            $script:RebootNeeded = $true
            Write-Note 'enable pending - reboot required'
        }
        else {
            Write-Note 'enabled'
        }
    }
}

#--- 3. winget packages -----------------------------------------------------
Write-Step "winget package set ($($WingetPackages.Count) entries)"
$installedIds = Get-WingetInventory
$wingetResult = Invoke-WingetPackageSet `
    -InstalledIds $installedIds `
    -DesiredIds $WingetPackages `
    -AlwaysUpgradeIds $WingetAlwaysUpgradePackages `
    -LegacyIds $WingetLegacyPackages

#--- Summary ----------------------------------------------------------------
Write-Step 'Summary'
Write-Note "winget: $($wingetResult.Installed.Count) installed now, $($wingetResult.UpdatedOrCurrent.Count) updated/current, $($wingetResult.Present.Count) ordinary present, $($wingetResult.RemovedLegacy.Count) legacy removed, $($wingetResult.Deferred.Count) deferred, $($wingetResult.Failed.Count) failed"
if ($wingetResult.Deferred.Count) { Write-Note "deferred (re-run after a reboot): $($wingetResult.Deferred -join ', ')" }
if ($wingetResult.Failed.Count)   { Write-Note "failed: $($wingetResult.Failed -join ', ')" }
if ($script:RebootNeeded) {
    Write-Warning 'A reboot is required to finish; re-run this script afterwards to pick up anything deferred.'
}
if ($wingetResult.Failed.Count) { exit 1 }
