<#
.SYNOPSIS
Idempotent Windows 11 workstation setup with core and full profiles.

.DESCRIPTION
Replaces the former comtrya manifest win11_workstation.yaml (comtrya is
unmaintained upstream). Apply from an elevated PowerShell; Windows PowerShell
5.1 is enough (PowerShell 7 is one of the packages it installs). -DryRun and
-Check never change the system and do not require elevation.

Profiles: core (the default) is every developer toolchain, editor, agent,
browser and everyday utility. Full adds games/launchers and media
servers/players/rippers.

Safe to re-run: every step reconciles state first. Installed desired packages
receive an exact-ID WinGet upgrade check unless they are explicitly exempted
as presence-only or -NoUpgrade is given.

  1. OpenSSH Server via enable-openssh-win11.ps1. Every run reconciles the
     capability, sshd state/start type, firewall rule, and DefaultShell.
  2. Hyper-V via the supported Windows optional feature - only with -HyperV.
     Windows 11 Pro/Enterprise (not Home) and compatible hardware are required.
  3. The winget package set for the selected profile. One `winget export`
     snapshot of what is installed decides what is missing. Installed desired
     packages are checked for updates every run, except for the explicitly
     presence-only Speedtest CLI. The legacy Antigravity IDE, VSCodium and
     standalone Rust MSI packages are removed in favor of Antigravity 2.0,
     Microsoft VS Code and rustup. "Already installed" and "reboot required"
     results count as success; any other failure is reported at the end
     (exit code 1) without stopping the run, so one broken installer never
     blocks the rest.
  4. Rust through rustup only: a stable default toolchain (only when none is
     configured) with rustfmt, clippy and rust-analyzer.

Exit codes: 0 converged (or -DryRun), 1 error/failed install, 2 drift found by
-Check.

.PARAMETER WorkstationProfile
core (default) or full; also accepted as -Profile. Full adds games/launchers and media extras.

.PARAMETER Check
Read-only state check: report CURRENT/DRIFT for OpenSSH, Hyper-V (with
-HyperV), every package in the profile, legacy packages, and the Rust
toolchain. Exits 2 when anything drifted. Requires Windows and winget.

.PARAMETER DryRun
Offline, read-only plan: print every step and WinGet ID the profile would
apply without querying or changing anything. Runs on any PowerShell host.

.PARAMETER NoUpgrade
Install missing packages only; skip upgrade checks of installed packages and
the rustup toolchain update.

.PARAMETER HyperV
Also enable the supported Hyper-V optional feature. Windows 11 Home is rejected;
supported editions generally need a reboot afterwards.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1 -Profile full -HyperV

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1 -Profile full -DryRun

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1 -Check -NoUpgrade
#>
[CmdletBinding()]
param(
    # Not named $Profile: that would shadow the automatic $PROFILE variable.
    [Alias('Profile')]
    [ValidateSet('core', 'full')]
    [string]$WorkstationProfile = 'core',

    [switch]$Check,

    [switch]$DryRun,

    [switch]$NoUpgrade,

    [switch]$HyperV
)

$ErrorActionPreference = 'Stop'
# winget's non-zero exit codes are interpreted by hand below; keep
# PowerShell 7.4+ from turning them into terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

#--- Config -----------------------------------------------------------------
$OpenSshDefaultShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

# core: every developer toolchain, editor, agent, browser and everyday utility.
$WingetPackages = @(
    '7zip.7zip'
    'Anthropic.ClaudeCode'
    'GIMP.GIMP.3'
    'Git.Git'
    'GitHub.GitHubDesktop'
    'GitHub.cli'
    'GoLang.Go'
    'Google.AndroidStudio'
    'Google.Antigravity'
    'Google.AntigravityCLI'
    'Google.Chrome'
    'Google.PlatformTools'
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
    'PuTTY.PuTTY'
    'Rufus.Rufus'
    # Rust comes only from rustup; the toolchain is initialized per user below.
    'Rustlang.Rustup'
    'SST.opencode'
    'Tailscale.Tailscale'
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
# full adds games/launchers and media servers, players and rippers.
$WingetFullPackages = @(
    'Apple.iTunes'
    # 'Blizzard.BattleNet'            # broken: interactive installer
    'ExtremeTuxRacer.ExtremeTuxRacer'
    'GOG.Galaxy'
    'Google.GoogleDrive'
    'GuinpinSoft.MakeMKV'
    'Plex.Plex'
    'Silicondust.HDHomeRun'
    'SuperTux.SuperTux'
    'SuperTuxKart.SuperTuxKart'
    'Unigine.HeavenBenchmark'
    'Valve.Steam'
)
$WingetPresenceOnlyPackages = @(
    # Preserve the deliberately fixed Speedtest CLI once it is installed.
    'Ookla.Speedtest.CLI'
)
$WingetLegacyPackages = @(
    'Google.AntigravityIDE'
    'VSCodium.VSCodium'
    # Standalone Rust installers conflict with the rustup-managed toolchain.
    'Rustlang.Rust.GNU'
    'Rustlang.Rust.MSVC'
)
$RustComponents = @('rustfmt', 'clippy', 'rust-analyzer')

# Balun (core, beside jm2.Tributary). Its WinGet manifest jm2.Balun is pending
# review, so apply prefers WinGet as soon as the ID resolves and otherwise
# falls back to the verified GitHub-release Inno Setup installer. Once the ID
# is published for good, move it into $WingetPackages and delete the fallback.
$BalunWingetId = 'jm2.Balun'
$BalunRepo = 'jm2/balun'
$BalunDisplayName = 'Balun'
# Inno Setup silent switches (build-aux/inno/balun.iss documents the same set).
$BalunInstallerArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')

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

# Python publishes a separate WinGet package ID for each 3.x minor release, so
# upgrading one exact ID can never migrate to the next minor. Resolve the
# highest numeric Python.Python.3.N ID exposed by the native WinGet source.
function Resolve-LatestPythonWingetPackageId {
    $prefix = 'Python.Python.3.'
    $output = @(
        & winget search --id $prefix --source winget --count 1000 `
            --accept-source-agreements --disable-interactivity 2>&1
    )
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw ("winget could not resolve the latest Python 3 package ID (0x{0:X8} / {0})" -f $code)
    }

    $text = ([string[]]$output) -join [Environment]::NewLine
    $idMatches = [regex]::Matches(
        $text,
        '(?<![A-Za-z0-9.])Python\.Python\.3\.(?<Minor>[0-9]+)(?=[\t ]|$)'
    )
    $ids = @($idMatches | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($ids.Count -eq 0) {
        throw 'winget returned no stable Python.Python.3.N package IDs'
    }

    $ranked = @($ids | ForEach-Object {
        $minor = 0
        if (-not [int]::TryParse($_.Substring($prefix.Length), [ref]$minor)) {
            throw "winget returned an unsupported Python package ID: $_"
        }
        [pscustomobject]@{ Id = $_; Minor = $minor }
    })
    $highestMinor = ($ranked | Measure-Object -Property Minor -Maximum).Maximum
    $latest = @($ranked | Where-Object { $_.Minor -eq $highestMinor })
    if ($latest.Count -ne 1) {
        throw "winget returned ambiguous Python 3 package IDs for minor $highestMinor"
    }
    return [string]$latest[0].Id
}

# Reconcile the package set from a single inventory snapshot. Installed desired
# packages are checked for updates unless explicitly declared presence-only.
# Superseded packages are removed before their supported replacements are
# installed/upgraded.
function Invoke-WingetPackageSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InstalledIds,

        [Parameter(Mandatory = $true)]
        [string[]]$DesiredIds,

        [string[]]$PresenceOnlyIds = @(),

        [string[]]$LegacyIds = @(),

        # Install missing packages only; leave installed ones at their version.
        [switch]$NoUpgrade
    )

    foreach ($id in $PresenceOnlyIds) {
        if ($DesiredIds -notcontains $id) {
            throw "Presence-only WinGet package is not in the desired set: $id"
        }
    }

    $present = @()
    $missing = @()
    $upgrade = @()
    foreach ($id in $DesiredIds) {
        if ($InstalledIds -contains $id) {
            if ($NoUpgrade -or $PresenceOnlyIds -contains $id) {
                $present += $id
            }
            else {
                $upgrade += $id
            }
        }
        else {
            $missing += $id
        }
    }

    Write-Note "$($present.Count) presence-only, $($missing.Count) missing, $($upgrade.Count) checking for updates"

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
        # include-unknown prevents packages whose installed version is not
        # registered from silently freezing forever. Such a vendor installer
        # may be invoked again on a later setup run; Speedtest is exempt above.
        & winget upgrade --id $id --exact --source winget --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
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

# Rust comes only from rustup. A fresh WinGet install is not on this session's
# PATH yet, so look in the per-user cargo directory first.
function Get-RustupPath {
    if ($env:USERPROFILE) {
        $candidate = Join-Path (Join-Path (Join-Path $env:USERPROFILE '.cargo') 'bin') 'rustup.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $command = Get-Command rustup -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

# Read-only: the stable toolchain's installed components (by base name), or
# $null when rustup has no usable stable toolchain.
function Get-RustupStableComponent {
    param([Parameter(Mandatory = $true)][string]$Rustup)
    $output = @(& $Rustup component list --installed --toolchain stable 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    $names = foreach ($line in $output) {
        $text = ([string]$line).Trim()
        foreach ($name in $RustComponents) {
            if ($text -eq $name -or $text.StartsWith("$name-")) { $name }
        }
    }
    return @($names | Select-Object -Unique)
}

function Test-RustupDefaultToolchain {
    param([Parameter(Mandatory = $true)][string]$Rustup)
    $output = @(& $Rustup default 2>$null)
    return ($LASTEXITCODE -eq 0 -and (([string[]]$output) -join ' ') -notmatch 'no default')
}

# Stable default (only when none is configured, so a chosen default survives)
# plus the editor components. Returns 'current', 'changed', 'deferred' or
# 'failed'.
function Initialize-RustupToolchain {
    param([switch]$NoUpgrade)
    $rustup = Get-RustupPath
    if (-not $rustup) {
        Write-Note 'rustup is not on PATH yet (fresh install); open a new session and re-run to initialize the stable toolchain'
        return 'deferred'
    }
    $changed = $false
    if (-not (Test-RustupDefaultToolchain -Rustup $rustup)) {
        & $rustup default stable | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning 'rustup default stable failed'; return 'failed' }
        $changed = $true
    }
    elseif (-not $NoUpgrade) {
        & $rustup update stable --no-self-update | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning 'rustup update stable failed'; return 'failed' }
    }
    $installed = Get-RustupStableComponent -Rustup $rustup
    $missing = @($RustComponents | Where-Object { $installed -notcontains $_ })
    if ($missing.Count) {
        & $rustup component add --toolchain stable @missing | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning "rustup component add failed: $($missing -join ', ')"; return 'failed' }
        $changed = $true
    }
    if ($changed) { return 'changed' }
    return 'current'
}

#--- Balun (WinGet first, verified GitHub release fallback) -----------------
# The Inno installer registers a fixed AppId under Uninstall\{...}_is1 with
# DisplayName "Balun"; per-user installs land under HKCU.
function Get-BalunInstall {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        $entry = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -eq $BalunDisplayName } |
            Select-Object -First 1
        if ($entry) {
            return [pscustomobject]@{ Version = [string]$entry.DisplayVersion; Key = [string]$entry.PSChildName }
        }
    }
    return $null
}

function Test-WingetPackageAvailable {
    param([Parameter(Mandatory = $true)][string]$Id)
    & winget show --id $Id --exact --source winget --accept-source-agreements --disable-interactivity | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-WindowsArchitectureName {
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($native) {
        'AMD64' { return 'x86_64' }
        'ARM64' { return 'aarch64' }
        default { throw "Balun publishes no Windows installer for architecture '$native'" }
    }
}

# Resolve the latest stable release asset for this architecture and the one
# SHA-256 that SHA256SUMS.txt and (when present) GitHub's asset digest agree on.
function Get-BalunRelease {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$BalunRepo/releases/latest" -Headers @{ 'User-Agent' = 'lan-ipxe-setup' }
    if ($release.prerelease -or $release.draft) {
        throw "latest $BalunRepo release is not a stable release"
    }
    $assetName = 'balun-windows-{0}-setup.exe' -f (Get-WindowsArchitectureName)
    $asset = @($release.assets | Where-Object { $_.name -eq $assetName })
    $sums = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' })
    if ($asset.Count -ne 1 -or $sums.Count -ne 1) {
        throw "release $($release.tag_name) lacks exactly one $assetName and SHA256SUMS.txt"
    }
    # Saved to a file: release downloads are application/octet-stream, which
    # Invoke-RestMethod does not reliably decode to text on 5.1.
    $sumsFile = Join-Path ([IO.Path]::GetTempPath()) ("balun-sums-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -Uri $sums[0].browser_download_url -OutFile $sumsFile -UseBasicParsing
        $sumsText = Get-Content -Raw -LiteralPath $sumsFile
    }
    finally {
        Remove-Item -LiteralPath $sumsFile -Force -ErrorAction SilentlyContinue
    }
    $lines = @($sumsText -split "`r?`n" | Where-Object { $_ -match ('^(?<Hash>[0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($assetName) + '\s*$') })
    if ($lines.Count -ne 1) {
        throw "SHA256SUMS.txt has no single entry for $assetName"
    }
    $expected = ([regex]::Match($lines[0], '^[0-9a-fA-F]{64}')).Value.ToLowerInvariant()
    $digest = [string]$asset[0].digest
    if ($digest) {
        if (-not $digest.StartsWith('sha256:') -or $digest.Substring(7).ToLowerInvariant() -ne $expected) {
            throw "GitHub asset digest for $assetName disagrees with SHA256SUMS.txt"
        }
    }
    return [pscustomobject]@{
        Version = ([string]$release.tag_name).TrimStart('v')
        Name = $assetName
        Url = [string]$asset[0].browser_download_url
        Sha256 = $expected
    }
}

function Install-BalunFromRelease {
    param([Parameter(Mandatory = $true)]$Release)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("balun-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $installer = Join-Path $dir $Release.Name
        Invoke-WebRequest -Uri $Release.Url -OutFile $installer -UseBasicParsing
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
        if ($actual -ne $Release.Sha256) {
            throw "Balun installer checksum mismatch: expected $($Release.Sha256), got $actual"
        }
        $process = Start-Process -FilePath $installer -ArgumentList $BalunInstallerArgs -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Balun installer exited with $($process.ExitCode)"
        }
    }
    finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-BalunInstall)) {
        throw 'Balun installer finished but no Balun uninstall entry was registered'
    }
}

# Returns 'current', 'installed', 'updated', 'deferred' or 'failed'. WinGet owns
# Balun whenever jm2.Balun resolves; it adopts a release-installed copy in place
# (same Inno AppId), so Balun is never installed twice.
function Invoke-BalunStep {
    param(
        [string[]]$InstalledIds = @(),
        [switch]$NoUpgrade
    )
    $existing = Get-BalunInstall
    try {
        if (Test-WingetPackageAvailable -Id $BalunWingetId) {
            if ($existing -and $NoUpgrade) {
                Write-Note "Balun $($existing.Version): present (-NoUpgrade)"
                return 'current'
            }
            $verb = if ($InstalledIds -contains $BalunWingetId) { 'upgrade' } else { 'install' }
            Write-Note "Balun: winget $verb $BalunWingetId"
            if ($verb -eq 'upgrade') {
                & winget upgrade --id $BalunWingetId --exact --source winget --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
            }
            else {
                # No --no-upgrade: an existing release install is adopted in place.
                & winget install --id $BalunWingetId --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
            }
            $code = $LASTEXITCODE
            if ($WingetRebootCodes -contains $code) { $script:RebootNeeded = $true }
            if ($WingetOkCodes.ContainsKey($code)) {
                Write-Note "Balun: $($WingetOkCodes[$code])"
                if ($existing) { return 'updated' }
                return 'installed'
            }
            if ($WingetDeferredCodes.ContainsKey($code)) {
                Write-Warning "Balun: $($WingetDeferredCodes[$code])"
                return 'deferred'
            }
            Write-Warning ("Balun: winget {0} exited with 0x{1:X8} ({1})" -f $verb, $code)
            return 'failed'
        }

        if ($existing -and $NoUpgrade) {
            Write-Note "Balun $($existing.Version): present (-NoUpgrade)"
            return 'current'
        }
        $release = Get-BalunRelease
        if ($existing -and $existing.Version -eq $release.Version) {
            Write-Note "Balun $($existing.Version): current (GitHub release)"
            return 'current'
        }
        Write-Note "Balun: installing verified GitHub release $($release.Version) ($($release.Name))"
        Install-BalunFromRelease -Release $release
        if ($existing) { return 'updated' }
        return 'installed'
    }
    catch {
        Write-Warning "Balun: $($_.Exception.Message)"
        return 'failed'
    }
}

# -Check output: one CURRENT/DRIFT line per item, drift counted for the exit code.
function Write-State {
    param(
        [Parameter(Mandatory = $true)][bool]$Current,
        [Parameter(Mandatory = $true)][string]$Item,
        [string]$Detail = ''
    )
    $label = if ($Current) { 'CURRENT' } else { 'DRIFT  '; $script:DriftCount++ }
    Write-Note ("{0} {1}{2}" -f $label, $Item, $(if ($Detail) { ": $Detail" } else { '' }))
}

#--- Preflight --------------------------------------------------------------
if ($Check -and $DryRun) {
    throw 'Choose one preview mode: -Check or -DryRun.'
}
$mode = if ($DryRun) { 'dry-run' } elseif ($Check) { 'check' } else { 'apply' }
if ($WorkstationProfile -eq 'full') {
    $WingetPackages += $WingetFullPackages
}
Write-Step "Profile: $WorkstationProfile; mode: $mode"

#--- Dry run: offline plan, no queries --------------------------------------
if ($DryRun) {
    Write-Step 'Plan (offline; nothing is queried or changed)'
    Write-Note 'OpenSSH Server: capability, sshd automatic + running, firewall rule TCP/22, DefaultShell'
    Write-Note "    DefaultShell = $OpenSshDefaultShell"
    if ($HyperV) {
        Write-Note 'Hyper-V: enable the Microsoft-Hyper-V optional feature (reboot usually required)'
    }
    else {
        Write-Note 'Hyper-V: skipped (pass -HyperV)'
    }
    $updatePolicy = if ($NoUpgrade) { 'install if missing (-NoUpgrade)' } else { 'install if missing, otherwise upgrade check' }
    Write-Note "WinGet packages ($($WingetPackages.Count) + latest Python.Python.3.N resolved at apply time; $updatePolicy):"
    foreach ($id in $WingetPackages) {
        $suffix = if ($WingetPresenceOnlyPackages -contains $id) { ' (presence-only)' } else { '' }
        Write-Note "    $id$suffix"
    }
    Write-Note "Balun: WinGet $BalunWingetId when it resolves; otherwise the latest stable $BalunRepo release"
    Write-Note '    balun-windows-<x86_64|aarch64>-setup.exe, SHA-256 checked against SHA256SUMS.txt and the asset digest,'
    Write-Note "    run silently ($($BalunInstallerArgs -join ' ')); skipped when present and -NoUpgrade"
    Write-Note 'Legacy packages removed if installed:'
    foreach ($id in $WingetLegacyPackages) { Write-Note "    $id" }
    Write-Note "Rust: rustup stable default (when none set) + $($RustComponents -join ', ')"
    exit 0
}

$script:RebootNeeded = $false
$script:DriftCount = 0
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install/update "App Installer" from the Microsoft Store, then re-run.'
}

#--- Check: read-only state report ------------------------------------------
if ($Check) {
    Write-Step 'OpenSSH Server'
    # The DISM-backed queries need elevation; unelevated, the service state
    # below still shows whether the capability is in place.
    try {
        $capability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        Write-State ($capability.State -eq 'Installed') 'OpenSSH.Server capability' ([string]$capability.State)
    }
    catch {
        Write-Note "NOTE    OpenSSH.Server capability: not queried ($($_.Exception.Message))"
    }
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    Write-State ($null -ne $service -and $service.Status -eq 'Running' -and [string]$service.StartType -eq 'Automatic') 'sshd service' $(if ($service) { "$($service.Status), $($service.StartType)" } else { 'missing' })
    $rule = @(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)
    Write-State ($rule.Count -eq 1 -and [string]$rule[0].Enabled -eq 'True') 'OpenSSH-Server-In-TCP firewall rule'
    $shell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
    Write-State ($shell -eq $OpenSshDefaultShell) 'OpenSSH DefaultShell' ([string]$shell)

    if ($HyperV) {
        Write-Step 'Hyper-V'
        try {
            $state = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop).State
            Write-State ($state -eq 'Enabled') 'Microsoft-Hyper-V' ([string]$state)
        }
        catch {
            Write-Note "NOTE    Microsoft-Hyper-V: not queried ($($_.Exception.Message)); rerun -Check elevated"
        }
    }

    Write-Step "winget package set ($($WingetPackages.Count) entries + Python 3)"
    $installedIds = Get-WingetInventory
    foreach ($id in $WingetPackages) {
        Write-State ($installedIds -contains $id) $id $(if ($installedIds -contains $id) { '' } else { 'not installed' })
    }
    $python = @($installedIds | Where-Object { $_ -like 'Python.Python.3.*' })
    Write-State ($python.Count -gt 0) 'Python 3' $(if ($python.Count) { ($python -join ', ') + ' (latest channel checked on apply)' } else { 'no Python.Python.3.N installed' })
    foreach ($id in $WingetLegacyPackages) {
        if ($installedIds -contains $id) { Write-State $false $id 'legacy package still installed' }
    }
    $balun = Get-BalunInstall
    $balunOwner = if ($installedIds -contains $BalunWingetId) { "WinGet $BalunWingetId" } else { 'GitHub release' }
    Write-State ($null -ne $balun) 'Balun' $(if ($balun) { "$($balun.Version) via $balunOwner" } else { 'not installed' })

    Write-Step 'Rust (rustup)'
    $rustup = Get-RustupPath
    if (-not $rustup) {
        Write-State $false 'rustup' 'not found'
    }
    else {
        Write-State (Test-RustupDefaultToolchain -Rustup $rustup) 'rustup default toolchain'
        $components = Get-RustupStableComponent -Rustup $rustup
        $missingComponents = @($RustComponents | Where-Object { $components -notcontains $_ })
        Write-State ($missingComponents.Count -eq 0) 'stable components' $(if ($missingComponents.Count) { 'missing ' + ($missingComponents -join ', ') } else { '' })
    }

    Write-Step 'Summary'
    Write-Note "$script:DriftCount drifted item(s)"
    if ($script:DriftCount) { exit 2 }
    exit 0
}

#--- Apply requires elevation -----------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Apply requires an elevated PowerShell (Run as administrator). -Check and -DryRun do not.'
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
Write-Step 'Resolving dynamic WinGet package channels'
$latestPythonPackageId = Resolve-LatestPythonWingetPackageId
$WingetPackages += $latestPythonPackageId
Write-Note "Python 3: selected current WinGet channel $latestPythonPackageId"

Write-Step "winget package set ($($WingetPackages.Count) entries)"
$installedIds = Get-WingetInventory
$wingetResult = Invoke-WingetPackageSet `
    -InstalledIds $installedIds `
    -DesiredIds $WingetPackages `
    -PresenceOnlyIds $WingetPresenceOnlyPackages `
    -LegacyIds $WingetLegacyPackages `
    -NoUpgrade:$NoUpgrade

Write-Step 'Balun (WinGet when published, otherwise verified GitHub release)'
$balunResult = Invoke-BalunStep -InstalledIds $installedIds -NoUpgrade:$NoUpgrade
Write-Note "Balun: $balunResult"

#--- 4. Rust toolchain (rustup only) ----------------------------------------
Write-Step 'Rust (rustup stable + components)'
$rustResult = Initialize-RustupToolchain -NoUpgrade:$NoUpgrade
Write-Note "rustup: $rustResult"

#--- Summary ----------------------------------------------------------------
Write-Step 'Summary'
Write-Note "winget: $($wingetResult.Installed.Count) installed now, $($wingetResult.UpdatedOrCurrent.Count) updated/current, $($wingetResult.Present.Count) presence-only, $($wingetResult.RemovedLegacy.Count) legacy removed, $($wingetResult.Deferred.Count) deferred, $($wingetResult.Failed.Count) failed"
if ($wingetResult.Deferred.Count) { Write-Note "deferred (re-run after a reboot): $($wingetResult.Deferred -join ', ')" }
if ($wingetResult.Failed.Count)   { Write-Note "failed: $($wingetResult.Failed -join ', ')" }
if ($script:RebootNeeded) {
    Write-Warning 'A reboot is required to finish; re-run this script afterwards to pick up anything deferred.'
}
if ($balunResult -eq 'deferred') { Write-Note 'deferred (re-run after a reboot): Balun' }
if ($wingetResult.Failed.Count -or $rustResult -eq 'failed' -or $balunResult -eq 'failed') { exit 1 }
