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
     presence-only Speedtest CLI and the Antigravity app, which updates
     itself. The legacy Antigravity IDE, VSCodium and
     standalone Rust MSI packages are removed in favor of Antigravity 2.0,
     Microsoft VS Code and rustup; the OpenCode CLI and desktop app
     (SST.opencode, SST.OpenCodeDesktop) and any native OpenCode install
     (%USERPROFILE%\.opencode\bin with its PATH entry and Git Bash rc lines,
     or a desktop app installed directly from opencode.ai) are removed in
     favor of Goose and
     Crush (charmbracelet.crush, Charm's own WinGet package; Crush has no
     desktop app). An update whose installer technology changed (LLVM 23
     moved from NSIS to MSI) is applied as an uninstall plus a fresh
     install, as winget requires. Run from the WinGet-installed PowerShell
     7, the Microsoft.PowerShell update is skipped (its MSI closes every
     pwsh, ending the run); run from powershell.exe to update it. Every
     PowerShell 7 install and update forces the MSI and opts it into
     Microsoft Update, so Windows Update keeps it current in between.
     "Already installed" and "reboot required"
     results count as success; any other failure is reported at the end
     (exit code 1) without stopping the run, so one broken installer never
     blocks the rest.
  4. Claude Code, Codex CLI, the Antigravity CLI and the goose CLI from each
     vendor's official per-user installer, so they update themselves in
     place. The WinGet packages they replace (Anthropic.ClaudeCode,
     OpenAI.Codex, Google.AntigravityCLI) are uninstalled once the native
     command runs. goose publishes x64 Windows builds only, so it is skipped
     on ARM64.
  5. Goose Desktop from the latest stable aaif-goose/goose release: the
     official Goose-win32-x64.zip, SHA-256 checked against the GitHub asset
     digest, unpacked per user under %LOCALAPPDATA%\Programs\Goose with a
     Start menu shortcut. The zip build does not update itself, so each run
     replaces it when a newer release exists. x64 only; skipped on ARM64.
  6. Rust through rustup only: a stable default toolchain (only when none is
     configured) with rustfmt, clippy and rust-analyzer.
  7. GooGet built from the head of google/googet with the GoLang.Go toolchain
     (the newest prebuilt googet.exe is v2.20.0 from 2024; until google/googet
     PRs #227 and #228 merge, a pinned jm2/googet commit carrying them,
     checked out with Git.Git), installed to
     %ProgramData%\GooGet the way googet's own install.ps1 does (GooGetRoot,
     machine PATH, ACLs), except that the root is created already locked and
     a pre-existing one is used only when nothing in it is owned or writable
     by any account but Administrators and SYSTEM and it holds no junctions
     or symlinks; otherwise apply stops for a person to remove it. Each run rebuilds when the source commit
     moved.
     googet.conf allows plain-HTTP repos and repos\game-packages.repo points
     at crossdock's game-packages GooGet repo on enthoo. The repo file from
     before the rename (repos\linux-packages.repo) is removed. From that repo,
     core installs crossdock and carryout and full adds the Linux full
     profile's games (bugdom, bugdom2, cro-mag-rally-net, mightymike,
     nanosaur, nanosaur2, ottomatic): missing ones are installed, installed
     ones updated to the repo's latest (missing only with -NoUpgrade), and
     everything is deferred while enthoo is unreachable.

Exit codes: 0 converged (or -DryRun), 1 error/failed install, 2 drift found by
-Check.

.PARAMETER WorkstationProfile
core (default) or full; also accepted as -Profile. Full adds games/launchers and media extras.

.PARAMETER Check
Read-only state check: report CURRENT/DRIFT for OpenSSH, Hyper-V (with
-HyperV), every package in the profile, legacy packages, the native CLIs,
Goose Desktop, the Rust toolchain, and GooGet with its repo. Exits 2 when anything drifted. Requires Windows and winget.

.PARAMETER DryRun
Offline, read-only plan: print every step and WinGet ID the profile would
apply without querying or changing anything. Runs on any PowerShell host.

.PARAMETER NoUpgrade
Install missing packages only; skip upgrade checks of installed packages,
native CLI and Goose Desktop refreshes, the rustup toolchain update, and
GooGet rebuilds.

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
    # Crush (CLI only; Charm ships no desktop app) from Charm's WinGet package.
    'charmbracelet.crush'
    'GIMP.GIMP.3'
    'Git.Git'
    'GitHub.GitHubDesktop'
    'GitHub.cli'
    'GoLang.Go'
    'Google.AndroidStudio'
    'Google.Antigravity'
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
    'PuTTY.PuTTY'
    'Rufus.Rufus'
    # Rust comes only from rustup; the toolchain is initialized per user below.
    'Rustlang.Rustup'
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
    # The Antigravity app is a per-user installer that updates itself; WinGet
    # only installs it when missing.
    'Google.Antigravity'
    # Preserve the deliberately fixed Speedtest CLI once it is installed.
    'Ookla.Speedtest.CLI'
)
$WingetLegacyPackages = @(
    'Google.AntigravityIDE'
    'VSCodium.VSCodium'
    # OpenCode CLI and desktop are replaced by Goose and Crush.
    'SST.opencode'
    'SST.OpenCodeDesktop'
    # Standalone Rust installers conflict with the rustup-managed toolchain.
    'Rustlang.Rust.GNU'
    'Rustlang.Rust.MSVC'
)
$RustComponents = @('rustfmt', 'clippy', 'rust-analyzer')

# Extra WinGet arguments by package ID, for every install, upgrade and
# reinstall of it. PowerShell 7 stays the MSI (WinGet can otherwise pick or
# match the Store build) and opts into Microsoft Update through the MSI's
# documented USE_MU/ENABLE_MU properties, so Windows Update keeps it current
# between runs - including the runs that skip its update because they execute
# from that pwsh.
$WingetPackageArgs = @{
    'Microsoft.PowerShell' = @('--installer-type', 'wix', '--custom', 'USE_MU=1 ENABLE_MU=1')
}

# AI CLIs that update themselves come from each vendor's official per-user
# installer: their WinGet portable/zip packages pin them to a WinGet-managed
# copy that never self-updates. Each replaces the WinGet package named by
# WingetId (when it has one), which is uninstalled only after the native
# command is verified. Architectures, when present, lists the native
# PROCESSOR_ARCHITECTURE values upstream builds for; others skip the tool.
# AddToUserPath puts the command's directory on the user PATH for installers
# that leave that to the user.
$NativeCliTools = @(
    @{
        Name = 'Claude Code'
        Installer = 'https://claude.ai/install.ps1'
        Root = 'USERPROFILE'
        RelativePath = '.local\bin\claude.exe'
        WingetId = 'Anthropic.ClaudeCode'
        # Its installer only warns when %USERPROFILE%\.local\bin is not on PATH.
        AddToUserPath = $true
        Environment = @{}
    }
    @{
        Name = 'Codex CLI'
        Installer = 'https://chatgpt.com/codex/install.ps1'
        Root = 'LOCALAPPDATA'
        RelativePath = 'Programs\OpenAI\Codex\bin\codex.exe'
        WingetId = 'OpenAI.Codex'
        Environment = @{ CODEX_NON_INTERACTIVE = 'true' }
    }
    @{
        # Its installer is a no-op once agy.exe exists; agy then updates itself.
        Name = 'Antigravity CLI'
        Installer = 'https://antigravity.google/cli/install.ps1'
        Root = 'LOCALAPPDATA'
        RelativePath = 'agy\bin\agy.exe'
        WingetId = 'Google.AntigravityCLI'
        Environment = @{}
    }
    @{
        # The URL goose's install docs give; `goose update` refreshes it in place.
        # Its default GOOSE_BIN_DIR is %USERPROFILE%\.local\bin. Upstream ships
        # x64 Windows builds only and the installer rejects ARM64.
        Name = 'goose CLI'
        Installer = 'https://raw.githubusercontent.com/aaif-goose/goose/main/download_cli.ps1'
        Root = 'USERPROFILE'
        RelativePath = '.local\bin\goose.exe'
        Architectures = @('AMD64')
        AddToUserPath = $true
        Environment = @{ CONFIGURE = 'false' }
    }
)

# Goose Desktop: Windows releases ship only the portable Goose-win32-x64.zip,
# which does not update itself, so apply replaces it whenever the latest
# stable release differs from the recorded one.
$GooseRepo = 'aaif-goose/goose'
$GooseDesktopAsset = 'Goose-win32-x64.zip'
$GooseDesktopArchitectures = @('AMD64')
$GooseDesktopMarkerName = '.lan-ipxe-release'

# Git Bash rc files OpenCode's own install script appends its PATH line to.
$OpenCodeRcFiles = @('.bashrc', '.bash_profile', '.profile')

# GooGet: the newest prebuilt googet.exe is v2.20.0 (2024) and v3.0.0 shipped
# none, so apply builds the default branch's head with Go (GoLang.Go, core).
# The module path and version are read from that commit's go.mod and
# googet.goospec, so a module rename upstream doesn't break the build.
$GooGetGitHubRepo = 'google/googet'
# Until google/googet PRs #227 and #228 (googet install with Provides) are
# merged, apply builds this jm2/googet commit instead: the head of its
# install-versioned-provides branch, which stacks both PRs on upstream master.
# The fork keeps the github.com/google/googet module path, so the proxy can't
# serve it; it is checked out with git (commit id verified) and built with
# `go build -mod=readonly`, which still verifies every dependency against
# go.sum. Once GitHub reports every listed PR merged, apply goes back to
# upstream's head on its own; then empty these three.
$GooGetPatchedRepo = 'jm2/googet'
$GooGetPatchedCommit = '645ecb0cbbef3fdb459807a54e1423949dcfa3db'
$GooGetPatchedPulls = @(227, 228)
$GooGetMarkerName = '.lan-ipxe-build'
# crossdock on enthoo serves game-packages' GooGet repo over plain HTTP on
# the trusted LAN, which googet 2.11+ refuses unless googet.conf sets
# allowunsafeurl.
$GooGetRepoName = 'game-packages'
$GooGetRepoUrl = 'http://192.168.1.11:8080/goo/game-packages'
# Repo files this script wrote under earlier names, by name and URL. Apply
# removes one only while it still holds exactly what was written, so a repo
# someone set up by hand under the same name stays.
# Packages installed from the game-packages GooGet repo. Core: jm2 tools with
# no WinGet package (Tributary and Balun stay on their vendor WinGet sources).
# Full adds the game set the Linux full profiles install: the Pangea ports,
# with Cro-Mag Rally as jm2's LAN-multiplayer fork. Real package names only:
# googet 3.4.1 cannot install a dependency that only a Provides satisfies.
$GooGetPackages = @('crossdock', 'carryout')
$GooGetFullPackages = @('bugdom', 'bugdom2', 'cro-mag-rally-net', 'mightymike', 'nanosaur', 'nanosaur2', 'ottomatic')
# The repo is LAN-only; a short probe keeps an off-LAN run from waiting on it.
$GooGetProbeTimeoutSeconds = 5
$GooGetRetiredRepos = @(
    @{ Name = 'linux-packages'; Url = 'http://192.168.1.11:8080/goo/linux-packages' }
)
# The only principals that may own or write anything under
# %ProgramData%\GooGet, as well-known SIDs (account names are localized):
# Administrators and SYSTEM. An owner keeps implicit WRITE_DAC, and googet
# runs elevated from the machine PATH. TrustedInstaller is deliberately
# absent: nothing there is a system file, and a hard link to one must fail.
$GooGetAclTrustedSids = @('S-1-5-32-544', 'S-1-5-18')

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
# The newer version uses a different installer technology (LLVM 23 moved from
# NSIS to MSI); winget asks for an uninstall followed by a fresh install.
$WingetInstallTechMismatchCode = 0x8A15008E # INSTALL_TECHNOLOGY_MISMATCH
# NSIS uninstallers relaunch themselves from %TEMP% and return at once, so the
# reinstall waits until winget no longer lists the package.
$WingetUninstallWaitSeconds = 600
$WingetUninstallPollSeconds = 5

#--- Helpers ----------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" }

# winget is an App Installer execution alias. When the Store updates or
# re-registers App Installer mid-run, the alias briefly cannot be launched
# ("Access is denied" or not found). Only a launch failure is retried - winget
# never started, so nothing runs twice. Output and $LASTEXITCODE pass through.
$WingetLaunchAttempts = 6
$WingetLaunchRetrySeconds = 10
function Invoke-Winget {
    for ($attempt = 1; ; $attempt++) {
        try {
            & winget @args
            return
        }
        catch [System.Management.Automation.ApplicationFailedException], [System.Management.Automation.CommandNotFoundException] {
            if ($attempt -ge $WingetLaunchAttempts) { throw }
            Write-Warning "winget could not be launched ($($_.Exception.Message.Split([Environment]::NewLine)[0])); retrying in $WingetLaunchRetrySeconds s"
            Start-Sleep -Seconds $WingetLaunchRetrySeconds
        }
    }
}

function Get-WingetPackageArgument {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($WingetPackageArgs -and $WingetPackageArgs.ContainsKey($Id)) { return @($WingetPackageArgs[$Id]) }
    return @()
}

# Ids of every installed package winget can match to a source. One
# `winget export` is far cheaper than a `winget list` per package, and its
# JSON is exact where the list's table output is truncated.
function Get-WingetInventory {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("winget-export-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        # 0x8A150035 means some unrelated installed applications could not be
        # matched to this source; the matched winget inventory is still valid.
        Invoke-Winget export -o $tmp --source winget --accept-source-agreements --disable-interactivity | Out-Null
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

# The uninstall registry entry winget correlates with an installed package,
# from the "Local Identifier: ARP\<Machine|User>\<arch>\<key>" detail; $null
# when winget reports none (or prints it in another UI language).
function Get-WingetArpEntry {
    param([Parameter(Mandatory = $true)][string]$Id)
    $output = @(Invoke-Winget list --id $Id --exact --details --source winget --accept-source-agreements --disable-interactivity 2>&1)
    if ($LASTEXITCODE -ne 0) { return $null }
    $match = [regex]::Match((([string[]]$output) -join "`n"), '(?m)^\s*Local Identifier:\s*ARP\\(?<Scope>Machine|User)\\(?<Arch>[^\\]+)\\(?<Key>[^\r\n]+?)\s*$')
    if (-not $match.Success) { return $null }
    $uninstall = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $path = if ($match.Groups['Scope'].Value -eq 'User') { "HKCU:\$uninstall" }
    elseif ($match.Groups['Arch'].Value -eq 'X86' -and [Environment]::Is64BitOperatingSystem) { "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" }
    else { "HKLM:\$uninstall" }
    # Concatenated, not Join-Path: Join-Path needs the registry drive to exist.
    return Get-ItemProperty -LiteralPath "$path\$($match.Groups['Key'].Value)" -ErrorAction SilentlyContinue
}

# NSIS-built executables (installers and uninstallers) carry this signature in
# their first header.
function Test-NsisExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -gt 64MB) { return $false }
    return [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Path)).Contains('NullsoftInst')
}

# Uninstalls a package ahead of a reinstall; returns $true when the uninstall
# was accepted. winget only knows an NSIS package registered without a quiet
# command as a plain "exe" and runs its uninstaller without /S, which then
# waits on a confirmation dialog, so NSIS uninstallers are run with /S here.
function Remove-WingetPackageForReinstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Id)
    if (-not $PSCmdlet.ShouldProcess($Id, 'uninstall ahead of a reinstall')) { return $false }
    $entry = Get-WingetArpEntry -Id $Id
    if ($entry -and $entry.PSObject.Properties.Name -contains 'UninstallString' -and $entry.UninstallString -and
        -not ($entry.PSObject.Properties.Name -contains 'QuietUninstallString' -and $entry.QuietUninstallString)) {
        $parsed = Split-UninstallCommand -Command ([string]$entry.UninstallString)
        if (Test-NsisExecutable -Path $parsed.FilePath) {
            Write-Note "$Id`: running its NSIS uninstaller silently"
            $code = Invoke-UninstallCommand -FilePath $parsed.FilePath -Arguments ("$($parsed.Arguments) /S".Trim())
            if ($code -ne 0) { Write-Warning "$Id`: NSIS uninstaller exited with $code" }
            return ($code -eq 0)
        }
    }
    Invoke-Winget uninstall --id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity | Out-Host
    $code = $LASTEXITCODE
    if ($WingetRebootCodes -contains $code) { $script:RebootNeeded = $true }
    if (-not $WingetRemoveOkCodes.ContainsKey($code)) {
        Write-Warning ("{0}: winget uninstall before reinstall exited with 0x{1:X8} ({1})" -f $Id, $code)
        return $false
    }
    return $true
}

# $true once winget no longer lists $Id as installed; $false on timeout.
function Wait-WingetPackageRemoved {
    param([Parameter(Mandatory = $true)][string]$Id)
    $deadline = (Get-Date).AddSeconds($WingetUninstallWaitSeconds)
    while ($true) {
        Invoke-Winget list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity | Out-Null
        if ($LASTEXITCODE -ne 0) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds $WingetUninstallPollSeconds
    }
}

# Python publishes a separate WinGet package ID for each 3.x minor release, so
# upgrading one exact ID can never migrate to the next minor. Resolve the
# highest numeric Python.Python.3.N ID exposed by the native WinGet source.
function Resolve-LatestPythonWingetPackageId {
    $prefix = 'Python.Python.3.'
    $output = @(
        Invoke-Winget search --id $prefix --source winget --count 1000 `
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

        # Installed packages whose update would close the process running this
        # script (the PowerShell 7 MSI shuts down every pwsh). Never upgraded here.
        [string[]]$HostIds = @(),

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
    $hostSkipped = @()
    foreach ($id in $DesiredIds) {
        if ($InstalledIds -contains $id) {
            if ($NoUpgrade -or $PresenceOnlyIds -contains $id) {
                $present += $id
            }
            elseif ($HostIds -contains $id) {
                $present += $id
                $hostSkipped += $id
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
    foreach ($id in $hostSkipped) {
        Write-Note "$id`: update skipped - it hosts this run; run the script from Windows PowerShell (powershell.exe) to update it"
    }

    $removedLegacy = @()
    $installedNow = @()
    $updatedOrCurrent = @()
    $deferred = @()
    $failed = @()

    foreach ($id in $LegacyIds) {
        if ($InstalledIds -notcontains $id) { continue }

        Write-Note "removing legacy $id"
        Invoke-Winget uninstall --id $id --exact --source winget --silent --accept-source-agreements --disable-interactivity | Out-Host
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
        $extra = @(Get-WingetPackageArgument -Id $id)
        Invoke-Winget install --id $id --exact --source winget --no-upgrade --silent --accept-package-agreements --accept-source-agreements --disable-interactivity @extra | Out-Host
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
        $extra = @(Get-WingetPackageArgument -Id $id)
        Invoke-Winget upgrade --id $id --exact --source winget --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity @extra | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq $WingetInstallTechMismatchCode) {
            Write-Note "$id`: the update uses a different installer technology; reinstalling"
            if (-not (Remove-WingetPackageForReinstall -Id $id)) {
                $failed += "upgrade $id"
                continue
            }
            if (-not (Wait-WingetPackageRemoved -Id $id)) {
                $failed += "upgrade $id"
                Write-Warning "$id`: still installed $WingetUninstallWaitSeconds s after its uninstaller returned; re-run to reinstall"
                continue
            }
            # A failed install leaves the package missing; the next run installs it.
            Invoke-Winget install --id $id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity @extra | Out-Host
            $code = $LASTEXITCODE
        }
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
        HostSkipped = @($hostSkipped)
        Installed = @($installedNow)
        UpdatedOrCurrent = @($updatedOrCurrent)
        RemovedLegacy = @($removedLegacy)
        Deferred = @($deferred)
        Failed = @($failed)
    }
}

# The machine's architecture, even from a 32-bit or emulated host process.
function Get-NativeProcessorArchitecture {
    if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
    return $env:PROCESSOR_ARCHITECTURE
}

function Test-NativeCliSupported {
    param([Parameter(Mandatory = $true)][hashtable]$Tool)
    if (-not $Tool.ContainsKey('Architectures')) { return $true }
    return @($Tool.Architectures) -contains (Get-NativeProcessorArchitecture)
}

# Appends a directory to the user PATH unless an entry already names it. The
# registry value is edited directly so %VAR% entries stay unexpanded (the
# .NET user-scope setter rewrites PATH as a plain string). Returns $true when
# PATH changed; new sessions see it, this one is updated in place.
function Add-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($raw -split ';' | Where-Object { $_ })
        foreach ($entry in $entries) {
            if ([Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\') -ieq $Directory.TrimEnd('\')) {
                return $false
            }
        }
        $key.SetValue('Path', ((@($entries) + $Directory) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    }
    finally {
        $key.Close()
    }
    $env:Path = "$env:Path;$Directory"
    return $true
}

function Get-NativeCliPath {
    param([Parameter(Mandatory = $true)][hashtable]$Tool)
    $base = [Environment]::GetEnvironmentVariable($Tool.Root)
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    return Join-Path $base $Tool.RelativePath
}

# Runs one vendor installer in a child PowerShell, so its own exit and
# strict-mode settings cannot end this script.
function Invoke-NativeCliInstaller {
    param([Parameter(Mandatory = $true)][hashtable]$Tool)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("native-cli-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $saved = @{}
    try {
        $installer = Join-Path $dir 'install.ps1'
        Invoke-WebRequest -Uri $Tool.Installer -OutFile $installer -UseBasicParsing
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) {
            throw "the downloaded $($Tool.Name) installer is not valid PowerShell"
        }
        foreach ($name in $Tool.Environment.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $Tool.Environment[$name])
        }
        $hostPath = (Get-Process -Id $PID).Path
        # Installers call tar.exe; launched from Git Bash, /usr/bin's GNU tar
        # would shadow Windows' bsdtar and read "C:\..." as a remote host.
        $savedPath = $env:Path
        $env:Path = (Join-Path $env:SystemRoot 'System32') + ";$env:Path"
        # Some installers (goose) download their archive into the working
        # directory; keep that inside the scratch directory.
        Push-Location -LiteralPath $dir
        try {
            & $hostPath -NoProfile -ExecutionPolicy Bypass -File $installer | Out-Host
            $code = $LASTEXITCODE
        }
        finally {
            Pop-Location
            $env:Path = $savedPath
        }
        if ($code -ne 0) {
            throw "the official $($Tool.Name) installer exited with $code"
        }
    }
    finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-NativeCliCommand {
    param([Parameter(Mandatory = $true)][string]$Path)
    & $Path --version | Out-Null
    return $LASTEXITCODE -eq 0
}

# Installs or refreshes each native CLI, then uninstalls the WinGet package it
# replaces. A failed install leaves that WinGet copy in place.
function Invoke-NativeCliSet {
    param(
        [string[]]$InstalledIds = @(),
        [switch]$NoUpgrade
    )
    $current = @()
    $installedNow = @()
    $skipped = @()
    $retired = @()
    $failed = @()
    foreach ($tool in $NativeCliTools) {
        if (-not (Test-NativeCliSupported -Tool $tool)) {
            Write-Note "$($tool.Name): skipped (upstream publishes no $(Get-NativeProcessorArchitecture) Windows build)"
            $skipped += $tool.Name
            continue
        }
        $path = Get-NativeCliPath -Tool $tool
        try {
            if (-not $path) { throw "%$($tool.Root)% is not set" }
            $existing = Test-Path -LiteralPath $path
            if ($existing -and $NoUpgrade) {
                Write-Note "$($tool.Name): present (-NoUpgrade)"
            }
            else {
                Write-Note "$($tool.Name): official installer $($tool.Installer)"
                Invoke-NativeCliInstaller -Tool $tool
                if (-not (Test-Path -LiteralPath $path)) {
                    throw "the official installer did not create $path"
                }
            }
            if (-not (Test-NativeCliCommand -Path $path)) { throw "$path --version failed" }
            if ($tool.AddToUserPath -and (Add-UserPathEntry -Directory (Split-Path -Parent $path))) {
                Write-Note "$($tool.Name): added $(Split-Path -Parent $path) to the user PATH"
            }
            if ($existing) { $current += $tool.Name } else { $installedNow += $tool.Name }
        }
        catch {
            Write-Warning "$($tool.Name): $($_.Exception.Message)"
            $failed += "install $($tool.Name)"
            continue
        }
        if (-not $tool.WingetId -or $InstalledIds -notcontains $tool.WingetId) { continue }
        Write-Note "removing $($tool.WingetId) (replaced by the self-updating native install)"
        Invoke-Winget uninstall --id $tool.WingetId --exact --source winget --silent --accept-source-agreements --disable-interactivity | Out-Host
        $code = $LASTEXITCODE
        if ($WingetRebootCodes -contains $code) { $script:RebootNeeded = $true }
        if ($WingetRemoveOkCodes.ContainsKey($code)) {
            $retired += $tool.WingetId
            Write-Note "$($tool.WingetId): $($WingetRemoveOkCodes[$code])"
        }
        else {
            $failed += "uninstall $($tool.WingetId)"
            Write-Warning ("{0}: winget uninstall exited with 0x{1:X8} ({1})" -f $tool.WingetId, $code)
        }
    }
    return [pscustomobject]@{
        Current = @($current)
        Installed = @($installedNow)
        Skipped = @($skipped)
        RetiredWinget = @($retired)
        Failed = @($failed)
    }
}

#--- PowerShell 7: the MSI, not the Microsoft Store package -------------------
# The Store package runs through an app-execution alias that Codex's Windows
# sandbox (a restricted token) cannot launch, so sandboxed agents can't run any
# command. WinGet can count the Store copy as Microsoft.PowerShell, so a plain
# install skips the MSI: force the MSI, verify it, then remove the Store copy.
function Get-PowerShellMsiPath { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }

function Get-StorePowerShell {
    @(Get-AppxPackage -Name Microsoft.PowerShell -AllUsers -ErrorAction SilentlyContinue)
}

function Test-PowerShellMsiRun {
    param([Parameter(Mandatory = $true)][string]$Path)
    & $Path -NoProfile -Command 'exit 0'
    return $LASTEXITCODE -eq 0
}

function Invoke-PowerShellMsiSwitch {
    $msi = Get-PowerShellMsiPath
    $status = 'current'
    if (-not (Test-Path -LiteralPath $msi)) {
        Write-Note 'PowerShell 7: installing the MSI (WinGet Microsoft.PowerShell, wix installer)'
        # --installer-type wix and the Microsoft Update opt-in come from $WingetPackageArgs.
        $extra = @(Get-WingetPackageArgument -Id 'Microsoft.PowerShell')
        Invoke-Winget install --id Microsoft.PowerShell --exact --source winget --force --silent --accept-package-agreements --accept-source-agreements --disable-interactivity @extra | Out-Host
        $code = $LASTEXITCODE
        if ($WingetRebootCodes -contains $code) { $script:RebootNeeded = $true }
        if (-not $WingetOkCodes.ContainsKey($code)) {
            Write-Warning ("PowerShell 7 MSI: winget install exited with 0x{0:X8} ({0})" -f $code)
            return 'failed'
        }
        $status = 'installed'
    }
    if (-not (Test-Path -LiteralPath $msi)) {
        Write-Warning "PowerShell 7 MSI: $msi is missing after install; leaving any Store copy in place"
        return 'failed'
    }
    if (-not (Test-PowerShellMsiRun -Path $msi)) {
        Write-Warning "PowerShell 7 MSI: $msi does not run; leaving any Store copy in place"
        return 'failed'
    }
    $store = Get-StorePowerShell
    if ($store.Count -and (Get-Process -Id $PID).Path -like '*\WindowsApps\*') {
        Write-Warning 'PowerShell 7 Store package: this script runs from it, so it stays; re-run from the MSI pwsh or powershell.exe to remove it'
        return 'store-kept'
    }
    if ($store.Count) {
        Write-Note "PowerShell 7: removing the Store package $($store[0].Version) (replaced by the MSI)"
        try {
            $store | Remove-AppxPackage -AllUsers -ErrorAction Stop
            if ($status -eq 'current') { $status = 'store-removed' }
        }
        catch {
            Write-Warning "PowerShell 7 Store package: $($_.Exception.Message)"
            return 'failed'
        }
    }
    return $status
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
    Invoke-Winget show --id $Id --exact --source winget --accept-source-agreements --disable-interactivity | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-WindowsArchitectureName {
    $native = Get-NativeProcessorArchitecture
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
                Invoke-Winget upgrade --id $BalunWingetId --exact --source winget --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
            }
            else {
                # No --no-upgrade: an existing release install is adopted in place.
                Invoke-Winget install --id $BalunWingetId --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
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

#--- OpenCode native-install purge ------------------------------------------
# Native installs WinGet does not see: the CLI from OpenCode's own install
# script (run under Git Bash) in %USERPROFILE%\.opencode\bin, the PATH lines
# that script adds, and a desktop app installed straight from opencode.ai.
# OpenCode's config and session data (~\.config\opencode,
# ~\.local\share\opencode) are left in place.
function Get-OpenCodeNativeBin {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $null }
    return Join-Path (Join-Path $env:USERPROFILE '.opencode') 'bin'
}

# Pure: the PATH entries that do not name $Directory (after expanding %VAR%).
function Get-PathListWithout {
    param(
        [string[]]$Entries = @(),
        [Parameter(Mandatory = $true)][string]$Directory
    )
    $wanted = $Directory.Replace('/', '\').TrimEnd('\')
    return @($Entries | Where-Object {
            $_ -and [Environment]::ExpandEnvironmentVariables($_).Replace('/', '\').TrimEnd('\') -ine $wanted
        })
}

function Get-UserPathEntry {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if (-not $key) { return @() }
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    finally {
        $key.Close()
    }
    return @($raw -split ';' | Where-Object { $_ })
}

# Mirrors Add-UserPathEntry: drops every user PATH entry naming $Directory,
# keeping %VAR% entries unexpanded. Returns $true when PATH changed.
function Remove-UserPathEntry {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Directory)
    if (-not $PSCmdlet.ShouldProcess('user PATH', "remove $Directory")) { return $false }
    $env:Path = (Get-PathListWithout -Entries @($env:Path -split ';') -Directory $Directory) -join ';'
    $entries = Get-UserPathEntry
    $kept = Get-PathListWithout -Entries $entries -Directory $Directory
    if ($kept.Count -eq $entries.Count) { return $false }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $key.SetValue('Path', ($kept -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    }
    finally {
        $key.Close()
    }
    return $true
}

# Pure: removes each block OpenCode's install script appends to a shell rc
# file - a blank line, "# opencode", then `export PATH=<home>/.opencode/bin:$PATH`
# - and nothing else. Line endings are kept as found.
function Get-OpenCodeRcCleanText {
    param([AllowEmptyString()][string]$Text = '')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`n")) {
        $bare = $line.TrimEnd("`r")
        if ($bare -match '^export PATH=\S*/\.opencode/bin:\$PATH$' -and
            $lines.Count -and $lines[$lines.Count - 1].TrimEnd("`r") -eq '# opencode') {
            $lines.RemoveAt($lines.Count - 1)
            if ($lines.Count -and $lines[$lines.Count - 1].TrimEnd("`r") -eq '') {
                $lines.RemoveAt($lines.Count - 1)
            }
            continue
        }
        $lines.Add($line)
    }
    return ($lines -join "`n")
}

# Pure: splits an uninstall command line into the executable and its
# arguments. Accepts a quoted path ("C:\x y\u.exe" /S) or an unquoted one
# ending in .exe (C:\x\u.exe /S).
function Split-UninstallCommand {
    param([Parameter(Mandatory = $true)][string]$Command)
    $text = $Command.Trim()
    if ($text -match '^"(?<File>[^"]+)"\s*(?<Arguments>.*)$' -or
        $text -match '^(?<File>.+?\.exe)(?:\s+(?<Arguments>.*))?$') {
        return [pscustomobject]@{ FilePath = $Matches.File; Arguments = ([string]$Matches.Arguments).Trim() }
    }
    throw "unrecognized uninstall command: $Command"
}

$OpenCodeUninstallWaitSeconds = 120

# Uninstall entries of a directly installed OpenCode desktop app (Tauri NSIS,
# per-user or per-machine). Only these exact display names are touched.
function Get-OpenCodeUninstallEntry {
    $roots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and [string]$_.DisplayName -imatch '^OpenCode( Desktop)?$' } |
            ForEach-Object {
                $quiet = if ($_.PSObject.Properties.Name -contains 'QuietUninstallString') { [string]$_.QuietUninstallString } else { '' }
                $plain = if ($_.PSObject.Properties.Name -contains 'UninstallString') { [string]$_.UninstallString } else { '' }
                [pscustomobject]@{
                    DisplayName = [string]$_.DisplayName
                    Key = [string]$_.PSPath
                    QuietUninstallString = $quiet
                    UninstallString = $plain
                }
            }
    }
}

function Invoke-UninstallCommand {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string]$Arguments = '')
    $start = @{ FilePath = $FilePath; Wait = $true; PassThru = $true }
    if ($Arguments) { $start.ArgumentList = $Arguments }
    return (Start-Process @start).ExitCode
}

function Get-OpenCodeRcPath {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return @() }
    return @($OpenCodeRcFiles | ForEach-Object { Join-Path $env:USERPROFILE $_ })
}

# Read-only: one description per OpenCode native leftover (for -Check).
function Get-OpenCodeNativeLeftover {
    $leftovers = @()
    $bin = Get-OpenCodeNativeBin
    if ($bin) {
        if (Test-Path -LiteralPath $bin) { $leftovers += "$bin (native CLI)" }
        $entries = Get-UserPathEntry
        if ((Get-PathListWithout -Entries $entries -Directory $bin).Count -ne @($entries).Count) {
            $leftovers += "user PATH entry $bin"
        }
    }
    foreach ($rc in Get-OpenCodeRcPath) {
        if (-not (Test-Path -LiteralPath $rc -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($rc)
        if ((Get-OpenCodeRcCleanText -Text $text) -cne $text) { $leftovers += "$rc (OpenCode PATH lines)" }
    }
    foreach ($entry in @(Get-OpenCodeUninstallEntry)) {
        $leftovers += "$($entry.DisplayName) (directly installed desktop app)"
    }
    return @($leftovers)
}

# Removes every leftover Get-OpenCodeNativeLeftover reports. Runs after the
# WinGet legacy removal, so WinGet-owned copies are already gone.
function Invoke-OpenCodeNativePurge {
    $removed = @()
    $failed = @()
    $bin = Get-OpenCodeNativeBin
    if ($bin) {
        try {
            if (Test-Path -LiteralPath $bin) {
                Remove-Item -LiteralPath $bin -Recurse -Force
                $removed += $bin
                $parent = Split-Path -Parent $bin
                if (-not @(Get-ChildItem -LiteralPath $parent -Force).Count) {
                    Remove-Item -LiteralPath $parent -Force
                }
            }
        }
        catch {
            Write-Warning "OpenCode CLI: could not remove $bin`: $($_.Exception.Message)"
            $failed += "remove $bin"
        }
        try {
            if (Remove-UserPathEntry -Directory $bin) { $removed += "user PATH entry $bin" }
        }
        catch {
            Write-Warning "OpenCode CLI: could not update the user PATH: $($_.Exception.Message)"
            $failed += 'remove the OpenCode user PATH entry'
        }
    }
    foreach ($rc in Get-OpenCodeRcPath) {
        if (-not (Test-Path -LiteralPath $rc -PathType Leaf)) { continue }
        try {
            $text = [IO.File]::ReadAllText($rc)
            $clean = Get-OpenCodeRcCleanText -Text $text
            if ($clean -cne $text) {
                [IO.File]::WriteAllText($rc, $clean, (New-Object System.Text.UTF8Encoding $false))
                $removed += "OpenCode PATH lines in $rc"
            }
        }
        catch {
            Write-Warning "OpenCode CLI: could not clean $rc`: $($_.Exception.Message)"
            $failed += "clean $rc"
        }
    }
    foreach ($entry in @(Get-OpenCodeUninstallEntry)) {
        try {
            $commandLine = if ($entry.QuietUninstallString) { $entry.QuietUninstallString }
            elseif ($entry.UninstallString) { "$($entry.UninstallString) /S" }
            else { throw 'no uninstall command is registered' }
            $parsed = Split-UninstallCommand -Command $commandLine
            $code = Invoke-UninstallCommand -FilePath $parsed.FilePath -Arguments $parsed.Arguments
            if ($code -ne 0) { throw "uninstaller exited with $code" }
            # NSIS uninstallers relaunch themselves from %TEMP% and return at
            # once, so give the real uninstall time to remove its entry.
            $deadline = (Get-Date).AddSeconds($OpenCodeUninstallWaitSeconds)
            while (@(Get-OpenCodeUninstallEntry | Where-Object { $_.Key -eq $entry.Key }).Count) {
                if ((Get-Date) -ge $deadline) { throw 'uninstaller finished but its uninstall entry remains' }
                Start-Sleep -Seconds 1
            }
            $removed += "$($entry.DisplayName) desktop app"
        }
        catch {
            Write-Warning "$($entry.DisplayName): $($_.Exception.Message)"
            $failed += "uninstall $($entry.DisplayName)"
        }
    }
    foreach ($item in $removed) { Write-Note "OpenCode: removed $item" }
    if (-not $removed.Count -and -not $failed.Count) { Write-Note 'OpenCode: no native installs found' }
    return [pscustomobject]@{ Removed = @($removed); Failed = @($failed) }
}

#--- Goose Desktop (verified GitHub release zip) ----------------------------
function Get-GooseDesktopRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
    return Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'Goose'
}

# The release this script last unpacked, read from the marker beside Goose.exe;
# $null when Goose Desktop is absent or was not installed by this script.
function Get-GooseDesktopInstall {
    $root = Get-GooseDesktopRoot
    if (-not $root) { return $null }
    $exe = Join-Path $root 'Goose.exe'
    $marker = Join-Path $root $GooseDesktopMarkerName
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $marker)) { return $null }
    $fields = @{}
    foreach ($line in @(Get-Content -LiteralPath $marker)) {
        if ($line -match '^(?<Key>[a-z0-9-]+)=(?<Value>.*)$') { $fields[$Matches.Key] = $Matches.Value }
    }
    return [pscustomobject]@{ Version = [string]$fields['version']; Sha256 = [string]$fields['sha256']; Exe = $exe }
}

# Pure selection over GitHub's latest-release JSON: one stable vX.Y.Z release
# with exactly one $GooseDesktopAsset under its own download path and a
# published SHA-256 digest.
function Select-GooseDesktopAsset {
    param([Parameter(Mandatory = $true)]$Release)
    if ($Release.prerelease -or $Release.draft) {
        throw "latest $GooseRepo release is not a stable release"
    }
    $tag = [string]$Release.tag_name
    if ($tag -notmatch '^v(?<Version>\d+\.\d+\.\d+)$') {
        throw "latest $GooseRepo release has an unsupported tag '$tag'"
    }
    $version = $Matches.Version
    $asset = @($Release.assets | Where-Object { $_.name -eq $GooseDesktopAsset })
    if ($asset.Count -ne 1) {
        throw "release $tag lacks exactly one $GooseDesktopAsset"
    }
    $url = [string]$asset[0].browser_download_url
    if ($url -ne "https://github.com/$GooseRepo/releases/download/$tag/$GooseDesktopAsset") {
        throw "$GooseDesktopAsset URL is outside the expected GitHub release path"
    }
    $digest = [string]$asset[0].digest
    if ($digest -notmatch '^sha256:(?<Hash>[0-9a-fA-F]{64})$') {
        throw "$GooseDesktopAsset has no published SHA-256 digest"
    }
    return [pscustomobject]@{
        Version = $version
        Name = $GooseDesktopAsset
        Url = $url
        Sha256 = $Matches.Hash.ToLowerInvariant()
    }
}

function Get-GooseDesktopRelease {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GooseRepo/releases/latest" -Headers @{ 'User-Agent' = 'lan-ipxe-setup' }
    return Select-GooseDesktopAsset -Release $release
}

# The unpacked app's root: the one directory holding Goose.exe beside the
# Electron resources/ folder. The zip wraps it (dist-windows/) and also ships
# the bundled CLI as resources\bin\goose.exe, which a case-insensitive name
# match alone would pick up too.
function Find-GooseDesktopAppDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $roots = @(Get-ChildItem -LiteralPath $Path -Recurse -File |
        Where-Object { $_.Name -ieq 'Goose.exe' -and (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'resources') -PathType Container) })
    if ($roots.Count -ne 1) {
        throw "the Goose Desktop archive does not contain exactly one Goose.exe app directory"
    }
    return $roots[0].DirectoryName
}

function Install-GooseDesktopShortcut {
    param([Parameter(Mandatory = $true)][string]$Target)
    $programs = [Environment]::GetFolderPath('Programs')
    if ([string]::IsNullOrWhiteSpace($programs)) { throw 'the per-user Start menu Programs folder is unknown' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $programs 'Goose.lnk'))
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = Split-Path -Parent $Target
    $shortcut.IconLocation = "$Target,0"
    $shortcut.Save()
}

# Downloads and verifies the zip, unpacks it beside the install directory, and
# swaps the new tree in only once it is complete; the previous copy is kept
# until the swap succeeds (a running Goose blocks the rename).
function Install-GooseDesktop {
    param([Parameter(Mandatory = $true)]$Release)
    $root = Get-GooseDesktopRoot
    if (-not $root) { throw '%LOCALAPPDATA% is not set' }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("goose-desktop-{0}" -f [Guid]::NewGuid().ToString('N'))
    $staging = "$root.lan-ipxe-new"
    $previous = "$root.lan-ipxe-old"
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $archive = Join-Path $dir $Release.Name
        Invoke-WebRequest -Uri $Release.Url -OutFile $archive -UseBasicParsing
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($actual -ne $Release.Sha256) {
            throw "Goose Desktop archive checksum mismatch: expected $($Release.Sha256), got $actual"
        }
        $extract = Join-Path $dir 'extract'
        Expand-Archive -LiteralPath $archive -DestinationPath $extract
        $appDirectory = Find-GooseDesktopAppDirectory -Path $extract
        foreach ($path in @($staging, $previous)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $root) | Out-Null
        Copy-Item -LiteralPath $appDirectory -Destination $staging -Recurse
        Set-Content -LiteralPath (Join-Path $staging $GooseDesktopMarkerName) -Value @(
            'managed-by=lan-ipxe/setup-win11-workstation.ps1'
            "version=$($Release.Version)"
            "source-url=$($Release.Url)"
            "sha256=$($Release.Sha256)"
        )
        if (Test-Path -LiteralPath $root) {
            try { Rename-Item -LiteralPath $root -NewName (Split-Path -Leaf $previous) }
            catch { throw "could not replace $root (close Goose and re-run): $($_.Exception.Message)" }
        }
        try { Rename-Item -LiteralPath $staging -NewName (Split-Path -Leaf $root) }
        catch {
            if (Test-Path -LiteralPath $previous) { Rename-Item -LiteralPath $previous -NewName (Split-Path -Leaf $root) }
            throw
        }
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
    }
    finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    Install-GooseDesktopShortcut -Target (Join-Path $root 'Goose.exe')
}

# Returns 'current', 'installed', 'updated', 'skipped' or 'failed'.
function Invoke-GooseDesktopStep {
    param([switch]$NoUpgrade)
    if ($GooseDesktopArchitectures -notcontains (Get-NativeProcessorArchitecture)) {
        Write-Note "Goose Desktop: skipped (upstream publishes no $(Get-NativeProcessorArchitecture) Windows build)"
        return 'skipped'
    }
    $existing = Get-GooseDesktopInstall
    try {
        if ($existing -and $NoUpgrade) {
            Write-Note "Goose Desktop $($existing.Version): present (-NoUpgrade)"
            return 'current'
        }
        $release = Get-GooseDesktopRelease
        if ($existing -and $existing.Version -eq $release.Version -and $existing.Sha256 -eq $release.Sha256) {
            Write-Note "Goose Desktop $($existing.Version): current"
            return 'current'
        }
        Write-Note "Goose Desktop: installing verified release $($release.Version) ($($release.Name))"
        Install-GooseDesktop -Release $release
        if ($existing) { return 'updated' }
        return 'installed'
    }
    catch {
        Write-Warning "Goose Desktop: $($_.Exception.Message)"
        return 'failed'
    }
}

#--- GooGet (built from google/googet head) ---------------------------------
function Get-GooGetRoot {
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { return $null }
    return Join-Path $env:ProgramData 'GooGet'
}

# googet.exe and the commit this script last built (from the marker beside
# it); Commit is empty for a googet installed some other way.
function Get-GooGetInstall {
    $root = Get-GooGetRoot
    if (-not $root) { return $null }
    $exe = Join-Path $root 'googet.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    $fields = @{}
    $marker = Join-Path $root $GooGetMarkerName
    if (Test-Path -LiteralPath $marker) {
        foreach ($line in @(Get-Content -LiteralPath $marker)) {
            if ($line -match '^(?<Key>[a-z0-9-]+)=(?<Value>.*)$') { $fields[$Matches.Key] = $Matches.Value }
        }
    }
    $repo = if ($fields['repo']) { [string]$fields['repo'] } elseif ($fields['commit']) { $GooGetGitHubRepo } else { '' }
    return [pscustomobject]@{ Exe = $exe; Commit = [string]$fields['commit']; Version = [string]$fields['version']; Repo = $repo }
}

# Pure: the build inputs from one commit's go.mod and googet.goospec.
function Select-GooGetSource {
    param(
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GoMod,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GooSpec,
        [string]$Repo = $GooGetGitHubRepo
    )
    if ($Commit -notmatch '^[0-9a-f]{40}$') { throw "unexpected $Repo commit id '$Commit'" }
    if ($GoMod -notmatch '(?m)^module\s+(?<Module>github\.com/google/googet(/v\d+)?)\s*$') {
        throw "go.mod at $Repo@$Commit does not declare a github.com/google/googet module"
    }
    $module = $Matches.Module
    if ($GooSpec -notmatch '\$version\s*:=\s*"(?<Version>\d+\.\d+\.\d+(@\d+)?)"') {
        throw "googet.goospec at $Repo@$Commit has no version"
    }
    return [pscustomobject]@{ Repo = $Repo; Commit = $Commit; Module = $module; Version = $Matches.Version }
}

# Pure: whether apply still builds the patched commit, given each listed
# upstream PR's merged state (a missing or false value counts as unmerged).
function Test-GooGetPatchPending {
    param([AllowEmptyCollection()][object[]]$Merged = @())
    if (-not $GooGetPatchedCommit -or @($GooGetPatchedPulls).Count -eq 0) { return $false }
    if (@($Merged).Count -lt @($GooGetPatchedPulls).Count) { return $true }
    return [bool](@($Merged | Where-Object { $_ -ne $true }).Count)
}

function Get-GooGetSource {
    $headers = @{ 'User-Agent' = 'lan-ipxe-setup' }
    $repo = $GooGetGitHubRepo
    $commit = ''
    if ($GooGetPatchedCommit) {
        $merged = @(foreach ($number in $GooGetPatchedPulls) {
            # A failed lookup (rate limit, network) keeps the patched build.
            try { [bool](Invoke-RestMethod -Uri "https://api.github.com/repos/$GooGetGitHubRepo/pulls/$number" -Headers $headers).merged }
            catch { Write-Warning "GooGet: could not read $GooGetGitHubRepo PR #$number ($($_.Exception.Message)); assuming unmerged"; $false }
        })
        if (Test-GooGetPatchPending -Merged $merged) {
            $repo = $GooGetPatchedRepo
            $commit = $GooGetPatchedCommit
        }
        else {
            Write-Note "GooGet: $GooGetGitHubRepo PRs #$($GooGetPatchedPulls -join ', #') are merged; building upstream head (the `$GooGetPatched* settings can be emptied)"
        }
    }
    if (-not $commit) {
        $commit = [string](Invoke-RestMethod -Uri "https://api.github.com/repos/$GooGetGitHubRepo/commits/HEAD" -Headers $headers).sha
    }
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw "unexpected $repo commit id '$commit'" }
    $raw = "https://raw.githubusercontent.com/$repo/$commit"
    $goMod = [string](Invoke-RestMethod -Uri "$raw/go.mod" -Headers $headers)
    $gooSpec = [string](Invoke-RestMethod -Uri "$raw/googet.goospec" -Headers $headers)
    return Select-GooGetSource -Repo $repo -Commit $commit -GoMod $goMod -GooSpec $gooSpec
}

# go.exe from PATH, or from the GoLang.Go MSI's directory when this session
# predates the install.
function Get-GoPath {
    $command = Get-Command go -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ($env:ProgramFiles) {
        $candidate = Join-Path $env:ProgramFiles 'Go\bin\go.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

# git.exe from PATH, or from the Git.Git installer's directory when this
# session predates the install.
function Get-GitPath {
    $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ($env:ProgramFiles) {
        $candidate = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

# Builds $Source with `go install module@commit` into a temp GOBIN (or, for
# a commit outside upstream, a git checkout verified against the commit id
# and `go build -mod=readonly`), checks the binary reports the expected
# version, then replaces googet.exe and writes the marker. The build pins
# Go's default module proxy and checksum database, so a machine-wide
# GOSUMDB=off or GOPRIVATE/GONOSUMDB override can't skip verification of the
# downloaded source.
function Install-GooGet {
    param(
        [Parameter(Mandatory = $true)]$Source,
        [Parameter(Mandatory = $true)][string]$Go,
        [string]$Git = ''
    )
    $fromCheckout = $Source.Repo -ne $GooGetGitHubRepo
    if ($fromCheckout -and -not $Git) { throw "building $($Source.Repo) needs git" }
    $root = Get-GooGetRoot
    if (-not $root) { throw '%ProgramData% is not set' }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("googet-build-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $saved = @{}
    $buildEnv = @{
        GOBIN = $dir; CGO_ENABLED = '0'; GOTOOLCHAIN = 'auto'; GOFLAGS = ''
        GOPROXY = 'https://proxy.golang.org'; GOSUMDB = 'sum.golang.org'
        GOPRIVATE = ''; GONOPROXY = ''; GONOSUMDB = ''; GOINSECURE = ''
        GIT_TERMINAL_PROMPT = '0'
    }
    try {
        foreach ($name in $buildEnv.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $buildEnv[$name], 'Process')
        }
        $ldflags = "-ldflags=-s -w -X main.version=$($Source.Version)"
        $built = Join-Path $dir 'googet.exe'
        if ($fromCheckout) {
            $src = Join-Path $dir 'src'
            & $Git init -q $src | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "git init failed (exit $LASTEXITCODE)" }
            & $Git -C $src fetch -q --depth 1 "https://github.com/$($Source.Repo).git" $Source.Commit | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "git fetch $($Source.Repo)@$($Source.Commit) failed (exit $LASTEXITCODE)" }
            & $Git -C $src -c advice.detachedHead=false checkout -q FETCH_HEAD | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "git checkout $($Source.Commit) failed (exit $LASTEXITCODE)" }
            $head = [string](& $Git -C $src rev-parse HEAD)
            if ($head.Trim() -ne $Source.Commit) { throw "checked-out commit '$head' is not $($Source.Commit)" }
            & $Go -C $src build -mod=readonly -trimpath $ldflags -o $built . | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "go build $($Source.Repo)@$($Source.Commit) failed (exit $LASTEXITCODE)" }
        }
        else {
            & $Go install -trimpath $ldflags "$($Source.Module)@$($Source.Commit)" | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "go install $($Source.Module)@$($Source.Commit) failed (exit $LASTEXITCODE)" }
        }
        if (-not (Test-Path -LiteralPath $built)) { throw 'the build produced no googet.exe' }
        $reported = (@(& $built -version 2>&1) -join ' ')
        if ($reported -notlike "*$($Source.Version)*") { throw "built googet.exe reports '$reported', expected $($Source.Version)" }
        Initialize-GooGetRoot | Out-Null
        try { Copy-Item -LiteralPath $built -Destination (Join-Path $root 'googet.exe') -Force }
        catch { throw "could not replace $root\googet.exe (is googet running?): $($_.Exception.Message)" }
        Set-Content -LiteralPath (Join-Path $root $GooGetMarkerName) -Value @(
            'managed-by=lan-ipxe/setup-win11-workstation.ps1'
            "version=$($Source.Version)"
            "repo=$($Source.Repo)"
            "commit=$($Source.Commit)"
            "module=$($Source.Module)"
        )
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Pure: googet.conf text with allowunsafeurl set to true, other keys kept.
function Get-GooGetConfText {
    param([AllowEmptyString()][string]$Text = '')
    $lines = @($Text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*allowunsafeurl\s*:' })
    while ($lines.Count -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -SkipLast 1) }
    return ((@($lines) + 'allowunsafeurl: true') -join "`n") + "`n"
}

# Pure: the repos\<name>.repo file googet's addrepo would write.
function Get-GooGetRepoFileText {
    return "- name: $GooGetRepoName`n  url: $GooGetRepoUrl`n"
}

# The retired repo files still present with the content this script
# wrote, as @{ Name; Path }.
function Get-GooGetRetiredRepoFile {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($r in $GooGetRetiredRepos) {
        $path = Join-Path (Join-Path $Root 'repos') "$($r.Name).repo"
        if ([string]::Equals((Read-TextOrEmpty -Path $path), "- name: $($r.Name)`n  url: $($r.Url)`n", [StringComparison]::Ordinal)) {
            [pscustomobject]@{ Name = $r.Name; Path = $path }
        }
    }
}

function Read-TextOrEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) }
    return ''
}

function Get-MachinePathEntry {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
    try { $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Close() }
    return @($raw -split ';' | Where-Object { $_ })
}

# Every item under $Root, without descending into reparse points (junctions
# and symlinks are reported, never followed).
function Get-GooGetTreeItem {
    param([Parameter(Mandatory = $true)][string]$Root)
    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-Item -LiteralPath $Root -Force))
    while ($stack.Count) {
        $item = $stack.Pop()
        $item
        if ($item -is [IO.DirectoryInfo] -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            foreach ($child in $item.GetFileSystemInfos()) { $stack.Push($child) }
        }
    }
}

# Pure: whether an ACE's access mask allows writing. .NET doesn't map
# generic rights, so GENERIC_WRITE and GENERIC_ALL (common on inherit-only
# ACEs) are checked as raw bits. FileSystemRights is an Int32 enum, so a mask
# with GENERIC_READ (0x80000000) arrives negative and sign-extends; keeping
# only the low 32 bits stops that from looking like every right.
function Test-GooGetWriteRight {
    param([Parameter(Mandatory = $true)][long]$Rights)
    $value = $Rights -band [long]4294967295
    $mask = [long][Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $mask = $mask -bor [long]1073741824 -bor [long]268435456   # GENERIC_WRITE, GENERIC_ALL
    return (($value -band $mask) -ne 0)
}

# Read-only: why the tree under an existing $Root can't be trusted by an
# elevated googet. Any finding means another account may have controlled part
# of it - or edited googet.conf, a .repo file or googet.exe - so apply refuses
# and nothing is repaired in place: in-place ACL repair can be steered through
# a junction created after the check, and relocking doesn't vouch for content
# written before it.
function Get-GooGetTreeProblem {
    param([Parameter(Mandatory = $true)][string]$Root)
    foreach ($item in Get-GooGetTreeItem -Root $Root) {
        $path = $item.FullName
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            "$path is a reparse point"
            continue
        }
        try { $acl = Get-Acl -LiteralPath $path }
        catch {
            "$path has an unreadable security descriptor"
            continue
        }
        $owner = [string]$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($GooGetAclTrustedSids -notcontains $owner) { "$path is owned by $owner" }
        if ($path.TrimEnd('\') -ieq $Root.TrimEnd('\') -and -not $acl.AreAccessRulesProtected) {
            "$path inherits permissions from its parent"
        }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if ($GooGetAclTrustedSids -contains $rule.IdentityReference.Value) { continue }
            if (Test-GooGetWriteRight -Rights ([long]$rule.FileSystemRights)) { "$path lets $($rule.IdentityReference.Value) write" }
        }
    }
}

# Creates $Root with install.ps1's ACLs (inheritance off; Administrators and
# SYSTEM full, Users read) and Administrators as owner in one call, so no
# other user can add anything before it is locked.
function New-GooGetRootDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not $PSCmdlet.ShouldProcess($Root, 'create with locked ACLs')) { return }
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($grant in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier $grant[0]
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $sid, $grant[1], $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    $security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::Create((New-Object IO.DirectoryInfo $Root), $security)
    }
    else {
        [IO.Directory]::CreateDirectory($Root, $security) | Out-Null
    }
}

# Makes sure %ProgramData%\GooGet is safe before anything is written to it. A
# missing root is created locked. An existing root (including one another
# user created between the check and the creation) is used only when the
# whole tree passes Get-GooGetTreeProblem; otherwise apply stops and a person
# removes it, after which the next run recreates it locked. Returns 'created'
# or 'current'.
function Initialize-GooGetRoot {
    $root = Get-GooGetRoot
    if (-not $root) { throw '%ProgramData% is not set' }
    $result = 'current'
    if (-not (Test-Path -LiteralPath $root)) {
        New-GooGetRootDirectory -Root $root
        $result = 'created'
    }
    $problems = @(Get-GooGetTreeProblem -Root $root)
    if ($problems.Count) {
        throw "refusing to use $root ($(@($problems | Select-Object -First 3) -join '; ')). Another account may have controlled it; inspect it, remove it, and re-run to recreate it locked. (If this root was made by this script, check the 'Default owner for objects created by members of the Administrators group' policy: 'Object creator' makes files owned by your user, not Administrators.)"
    }
    return $result
}

# Read-only: what install.ps1 and this repo's config would still change.
function Get-GooGetConfigurationDrift {
    $root = Get-GooGetRoot
    if (-not $root) { return @('%ProgramData% is not set') }
    $drift = @()
    if (-not (Test-Path -LiteralPath $root)) { $drift += 'root missing' }
    else {
        try {
            $problems = @(Get-GooGetTreeProblem -Root $root)
            if ($problems.Count) { $drift += "untrusted root, refused on apply ($(@($problems | Select-Object -First 3) -join '; '))" }
        }
        catch { $drift += "root permissions (not readable: $($_.Exception.Message))" }
    }
    if ([Environment]::GetEnvironmentVariable('GooGetRoot', 'Machine') -ne $root) { $drift += 'GooGetRoot machine variable' }
    if ((Get-PathListWithout -Entries (Get-MachinePathEntry) -Directory $root).Count -eq (Get-MachinePathEntry).Count) { $drift += 'machine PATH entry' }
    $conf = Read-TextOrEmpty -Path (Join-Path $root 'googet.conf')
    if ($conf -ne (Get-GooGetConfText -Text $conf)) { $drift += 'googet.conf allowunsafeurl' }
    $repoFile = Join-Path (Join-Path $root 'repos') "$GooGetRepoName.repo"
    if ((Read-TextOrEmpty -Path $repoFile) -ne (Get-GooGetRepoFileText)) { $drift += "$GooGetRepoName repo" }
    foreach ($old in @(Get-GooGetRetiredRepoFile -Root $root)) { $drift += "retired $($old.Name) repo" }
    return $drift
}

# Applies googet's install.ps1 (ACLs on the root, GooGetRoot, machine PATH)
# and this repo's googet.conf and repo file. The root is created locked or
# validated first (Initialize-GooGetRoot), so it is safe before it joins
# PATH. Files are UTF-8 without a BOM. Returns the names of the items it
# changed.
function Sync-GooGetConfiguration {
    $root = Get-GooGetRoot
    if (-not $root) { throw '%ProgramData% is not set' }
    $changed = @()
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $rootState = Initialize-GooGetRoot
    if ($rootState -ne 'current') { $changed += "root $rootState" }
    if ([Environment]::GetEnvironmentVariable('GooGetRoot', 'Machine') -ne $root) {
        [Environment]::SetEnvironmentVariable('GooGetRoot', $root, 'Machine')
        $changed += 'GooGetRoot'
    }
    $env:GooGetRoot = $root
    $entries = Get-MachinePathEntry
    if ((Get-PathListWithout -Entries $entries -Directory $root).Count -eq $entries.Count) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        try { $key.SetValue('Path', ((@($entries) + $root) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
        finally { $key.Close() }
        $env:Path = "$env:Path;$root"
        $changed += 'machine PATH'
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'repos') | Out-Null
    $confPath = Join-Path $root 'googet.conf'
    $conf = Read-TextOrEmpty -Path $confPath
    $wantConf = Get-GooGetConfText -Text $conf
    if ($conf -ne $wantConf) { [IO.File]::WriteAllText($confPath, $wantConf, $utf8); $changed += 'googet.conf' }
    $repoFile = Join-Path (Join-Path $root 'repos') "$GooGetRepoName.repo"
    $wantRepo = Get-GooGetRepoFileText
    if ((Read-TextOrEmpty -Path $repoFile) -ne $wantRepo) { [IO.File]::WriteAllText($repoFile, $wantRepo, $utf8); $changed += "$GooGetRepoName repo" }
    foreach ($old in @(Get-GooGetRetiredRepoFile -Root $root)) {
        Remove-Item -LiteralPath $old.Path -Force
        $changed += "removed $($old.Name) repo"
    }
    return $changed
}

# Returns 'current', 'changed', 'installed', 'updated', 'deferred' or 'failed'.
function Invoke-GooGetStep {
    param([switch]$NoUpgrade)
    try {
        $existing = Get-GooGetInstall
        $result = 'current'
        if ($existing -and $NoUpgrade) {
            Write-Note "GooGet $($existing.Version): present (-NoUpgrade)"
        }
        else {
            $source = Get-GooGetSource
            $short = $source.Commit.Substring(0, 12)
            if ($existing -and $existing.Commit -eq $source.Commit) {
                Write-Note "GooGet $($existing.Version) ($short): current"
            }
            else {
                $go = Get-GoPath
                if (-not $go) {
                    Write-Note 'GooGet: Go is not installed yet; re-run after GoLang.Go installs'
                    return 'deferred'
                }
                $git = ''
                if ($source.Repo -ne $GooGetGitHubRepo) {
                    $git = Get-GitPath
                    if (-not $git) {
                        Write-Note 'GooGet: Git is not installed yet; re-run after Git.Git installs'
                        return 'deferred'
                    }
                }
                Write-Note "GooGet: building $($source.Version) from $($source.Repo)@$short"
                Install-GooGet -Source $source -Go $go -Git $git
                $result = if ($existing) { 'updated' } else { 'installed' }
            }
        }
        $changed = @(Sync-GooGetConfiguration)
        if ($changed.Count) {
            Write-Note "GooGet: set $($changed -join ', ')"
            if ($changed -contains 'GooGetRoot' -or $changed -contains 'machine PATH') {
                Write-Note 'GooGet: open a new shell to use googet (shells started earlier lack GooGetRoot and the PATH entry)'
            }
            if ($result -eq 'current') { $result = 'changed' }
        }
        return $result
    }
    catch {
        Write-Warning "GooGet: $($_.Exception.Message)"
        return 'failed'
    }
}

#--- game-packages GooGet packages -----------------------------------------
# googet with the root passed explicitly: shells started before GooGetRoot
# was set machine-wide do not have it. Output and $LASTEXITCODE pass through.
function Invoke-GooGetCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    & $Exe -root $Root @Arguments
}

# Pure: package names from `googet installed` output ("  <name>.<arch> <ver>").
function Get-GooGetInstalledName {
    param([AllowEmptyCollection()][string[]]$Lines = @())
    foreach ($line in $Lines) {
        if ([string]$line -match '^\s+(?<Name>\S+)\.(?<Arch>noarch|x86_64|x86_32|arm64)\s+\S+\s*$') { $Matches.Name }
    }
}

# Installed package names. `googet installed` exits 1 when nothing is
# installed, which is not an error.
function Get-GooGetInstalledPackage {
    param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][string]$Root)
    $output = @(Invoke-GooGetCommand -Exe $Exe -Root $Root -Arguments @('installed') 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -and -not ($output -match '^Installed packages:')) {
        throw "googet installed exited with $LASTEXITCODE`: $($output -join ' ')"
    }
    return @(Get-GooGetInstalledName -Lines $output)
}

# googet reads <repo>/index.gz, falling back to <repo>/index.
function Test-GooGetRepoReachable {
    foreach ($index in @('index.gz', 'index')) {
        try {
            Invoke-WebRequest -Uri "$GooGetRepoUrl/$index" -UseBasicParsing -TimeoutSec $GooGetProbeTimeoutSeconds | Out-Null
            return $true
        }
        catch {
            Write-Verbose "game-packages probe $index`: $($_.Exception.Message)"
        }
    }
    return $false
}

# Installs the missing packages and, unless -NoUpgrade, brings installed ones
# to the repo's latest (googet install upgrades an older installed version
# and skips a current one). Off the LAN, or before googet exists, everything
# is deferred to a later run rather than failed.
function Invoke-GooGetPackageSet {
    param([Parameter(Mandatory = $true)][string[]]$Packages, [switch]$NoUpgrade)
    $result = [pscustomobject]@{ Current = @(); Installed = @(); Deferred = @(); Failed = @() }
    $googet = Get-GooGetInstall
    if (-not $googet) {
        Write-Note 'game-packages: googet is not built yet; these install on a later run'
        $result.Deferred = @($Packages)
        return $result
    }
    if (-not (Test-GooGetRepoReachable)) {
        Write-Note "game-packages: $GooGetRepoUrl is unreachable; $($Packages -join ', ') install from it once enthoo answers"
        $result.Deferred = @($Packages)
        return $result
    }
    $root = Get-GooGetRoot
    try {
        $before = @(Get-GooGetInstalledPackage -Exe $googet.Exe -Root $root)
        $missing = @($Packages | Where-Object { $before -notcontains $_ })
        $targets = if ($NoUpgrade) { $missing } else { @($Packages) }
        if ($targets.Count) {
            Write-Note "game-packages: googet install $($targets -join ' ')"
            Invoke-GooGetCommand -Exe $googet.Exe -Root $root -Arguments (@('-noconfirm', 'install') + $targets) | Out-Host
            $code = $LASTEXITCODE
            $after = @(Get-GooGetInstalledPackage -Exe $googet.Exe -Root $root)
            $result.Failed = @($Packages | Where-Object { $after -notcontains $_ })
            if ($code -ne 0 -and -not $result.Failed.Count) {
                Write-Warning "game-packages: googet install exited with $code"
                $result.Failed = @($targets)
            }
        }
        $result.Installed = @($missing | Where-Object { $result.Failed -notcontains $_ })
        $result.Current = @($Packages | Where-Object { $missing -notcontains $_ -and $result.Failed -notcontains $_ })
    }
    catch {
        Write-Warning "game-packages: $($_.Exception.Message)"
        $result.Failed = @($Packages)
        $result.Installed = @()
        $result.Current = @()
    }
    foreach ($name in $result.Failed) { Write-Warning "game-packages: $name is not installed" }
    return $result
}

# Mirrors enable-openssh-win11.ps1 (which -Check cannot run unelevated):
# installing the OpenSSH.Server capability registers sshd on the inbox binary.
function Test-InboxSshdService {
    $imagePath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if (-not $imagePath) { return $false }
    $inbox = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    $registered = [Environment]::ExpandEnvironmentVariables(([string]$imagePath).Trim().Trim('"'))
    return (($registered -replace '/', '\') -ieq ($inbox -replace '/', '\')) -and (Test-Path -LiteralPath $inbox -PathType Leaf)
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
    $GooGetPackages += $GooGetFullPackages
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
    Write-Note 'Native OpenCode installs removed after the WinGet legacy packages:'
    Write-Note '    %USERPROFILE%\.opencode\bin and its user PATH entry; the "# opencode" PATH lines in'
    Write-Note "    %USERPROFILE%\{$($OpenCodeRcFiles -join ',')}; a directly installed OpenCode desktop app (its uninstaller)"
    Write-Note 'Self-updating native CLIs (official per-user installers; the WinGet package each replaces is removed afterwards):'
    foreach ($tool in $NativeCliTools) {
        $details = @()
        if ($tool.WingetId) { $details += "replaces $($tool.WingetId)" }
        if ($tool.ContainsKey('Architectures')) { $details += "$($tool.Architectures -join '/') only; skipped elsewhere" }
        $suffix = if ($details.Count) { " ($($details -join '; '))" } else { '' }
        Write-Note "    $($tool.Name): $($tool.Installer) -> %$($tool.Root)%\$($tool.RelativePath)$suffix"
    }
    Write-Note "Goose Desktop ($($GooseDesktopArchitectures -join '/') only; skipped elsewhere): latest stable $GooseRepo release $GooseDesktopAsset,"
    Write-Note '    SHA-256 checked against the GitHub asset digest, unpacked to %LOCALAPPDATA%\Programs\Goose + Start menu shortcut;'
    Write-Note '    replaced when a newer release exists; skipped when present and -NoUpgrade'
    Write-Note "Rust: rustup stable default (when none set) + $($RustComponents -join ', ')"
    if ($GooGetPatchedCommit) {
        Write-Note "GooGet: go build of $GooGetPatchedRepo@$($GooGetPatchedCommit.Substring(0, 12)) (git checkout) until $GooGetGitHubRepo PRs #$($GooGetPatchedPulls -join ', #') merge,"
        Write-Note "    then go install from the head of $GooGetGitHubRepo (rebuilt when the source moves; skipped when present and -NoUpgrade)"
    }
    else {
        Write-Note "GooGet: go install from the head of $GooGetGitHubRepo (rebuilt when it moves; skipped when present and -NoUpgrade)"
    }
    Write-Note '    into %ProgramData%\GooGet with GooGetRoot, the machine PATH entry and ACLs as googet''s install.ps1 sets them;'
    Write-Note "    googet.conf allowunsafeurl: true; repo $GooGetRepoName -> $GooGetRepoUrl"
    foreach ($r in $GooGetRetiredRepos) { Write-Note "    removes repos\$($r.Name).repo while it still points at $($r.Url)" }
    $gooPolicy = if ($NoUpgrade) { 'install if missing (-NoUpgrade)' } else { 'install if missing, otherwise update to the repo''s latest' }
    Write-Note "game-packages GooGet packages ($gooPolicy; deferred while enthoo is unreachable):"
    foreach ($name in $GooGetPackages) { Write-Note "    $name" }
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
    # The capability is what registers sshd on the inbox binary, so that
    # registration answers without the slow DISM query. Otherwise ask DISM,
    # which needs elevation (and the native Windows PowerShell host); when it
    # cannot answer, the service state below still shows what is missing.
    if (Test-InboxSshdService) {
        Write-State $true 'OpenSSH.Server capability' 'inbox sshd service registered'
    }
    else {
        try {
            $capability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
            Write-State ($capability.State -eq 'Installed') 'OpenSSH.Server capability' ([string]$capability.State)
        }
        catch {
            Write-Note "NOTE    OpenSSH.Server capability: not queried ($($_.Exception.Message))"
        }
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
    foreach ($tool in $NativeCliTools) {
        if (-not (Test-NativeCliSupported -Tool $tool)) {
            Write-Note "NOTE    $($tool.Name) (native): not available for $(Get-NativeProcessorArchitecture)"
            continue
        }
        $path = Get-NativeCliPath -Tool $tool
        $present = $path -and (Test-Path -LiteralPath $path)
        Write-State $present "$($tool.Name) (native)" $(if ($present) { $path } else { 'not installed' })
        if ($tool.WingetId -and $installedIds -contains $tool.WingetId) {
            Write-State $false $tool.WingetId 'replaced by the native install; removed on apply'
        }
    }
    if ($GooseDesktopArchitectures -contains (Get-NativeProcessorArchitecture)) {
        $gooseDesktop = Get-GooseDesktopInstall
        Write-State ($null -ne $gooseDesktop) 'Goose Desktop' $(if ($gooseDesktop) { "$($gooseDesktop.Version) (newer releases checked on apply)" } else { 'not installed' })
    }
    else {
        Write-Note "NOTE    Goose Desktop: not available for $(Get-NativeProcessorArchitecture)"
    }
    foreach ($leftover in Get-OpenCodeNativeLeftover) {
        Write-State $false "OpenCode: $leftover" 'native install; removed on apply'
    }
    $pwshMsi = Get-PowerShellMsiPath
    $hasMsi = Test-Path -LiteralPath $pwshMsi
    Write-State $hasMsi 'PowerShell 7 (MSI)' $(if ($hasMsi) { $pwshMsi } else { 'not installed' })
    $storePwsh = Get-StorePowerShell
    if ($storePwsh.Count) {
        Write-State $false 'PowerShell 7 (Store package)' "$($storePwsh[0].Version); its alias can't run in Codex's sandbox; replaced by the MSI on apply"
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

    Write-Step 'GooGet'
    $googet = Get-GooGetInstall
    $googetDetail = if (-not $googet) { 'not installed' }
        elseif ($googet.Commit) { "$($googet.Version) ($($googet.Repo)@$($googet.Commit.Substring(0, 12)); rebuilt on apply when the source moves)" }
        else { 'not built by this script; rebuilt from source on apply' }
    Write-State ($null -ne $googet -and [bool]$googet.Commit) 'googet.exe' $googetDetail
    $googetDrift = @(Get-GooGetConfigurationDrift)
    Write-State ($googetDrift.Count -eq 0) "GooGet configuration ($GooGetRepoName repo)" $(if ($googetDrift.Count) { 'missing ' + ($googetDrift -join ', ') } else { '' })
    if ($googet) {
        try {
            $gooInstalled = @(Get-GooGetInstalledPackage -Exe $googet.Exe -Root (Get-GooGetRoot))
            foreach ($name in $GooGetPackages) {
                Write-State ($gooInstalled -contains $name) "$name (game-packages)" $(if ($gooInstalled -contains $name) { '' } else { 'not installed' })
            }
        }
        catch {
            Write-Note "NOTE    game-packages packages: not queried ($($_.Exception.Message))"
        }
    }
    else {
        Write-Note "NOTE    game-packages packages ($($GooGetPackages -join ', ')): googet is not installed; they install after it"
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
$openSshHelper = Join-Path $PSScriptRoot 'enable-openssh-win11.ps1'
# The read-only probe never queries DISM, so a converged machine skips the
# slow capability check entirely.
if (& $openSshHelper -Test) {
    Write-Note 'capability, sshd, firewall, and DefaultShell already in place'
}
else {
    & $openSshHelper
    $defaultShell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell
    if ($defaultShell -ne $OpenSshDefaultShell) {
        throw 'OpenSSH helper returned without converging DefaultShell'
    }
    Write-Note 'capability, sshd, firewall, and DefaultShell reconciled'
}

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
# Under the WinGet-installed PowerShell 7, its MSI update would close this run
# mid-way (and roll back), so that one update is left to a powershell.exe run.
$hostIds = @()
if ($PSVersionTable.PSEdition -eq 'Core' -and $env:ProgramFiles -and
    (Get-Process -Id $PID).Path -like (Join-Path $env:ProgramFiles 'PowerShell\*')) {
    $hostIds += 'Microsoft.PowerShell'
}
$wingetResult = Invoke-WingetPackageSet `
    -InstalledIds $installedIds `
    -DesiredIds $WingetPackages `
    -PresenceOnlyIds $WingetPresenceOnlyPackages `
    -LegacyIds $WingetLegacyPackages `
    -HostIds $hostIds `
    -NoUpgrade:$NoUpgrade

Write-Step 'OpenCode native installs (replaced by Goose and Crush)'
$openCodeResult = Invoke-OpenCodeNativePurge

Write-Step 'PowerShell 7 (MSI, not the Store package)'
$pwshResult = Invoke-PowerShellMsiSwitch
Write-Note "PowerShell 7: $pwshResult"

Write-Step 'Balun (WinGet when published, otherwise verified GitHub release)'
$balunResult = Invoke-BalunStep -InstalledIds $installedIds -NoUpgrade:$NoUpgrade
Write-Note "Balun: $balunResult"

#--- 4. Self-updating native CLIs ------------------------------------------
Write-Step 'Claude Code, Codex CLI, Antigravity CLI and goose CLI (official native installers)'
$nativeResult = Invoke-NativeCliSet -InstalledIds $installedIds -NoUpgrade:$NoUpgrade

#--- 5. Goose Desktop (verified release zip) --------------------------------
Write-Step 'Goose Desktop (verified GitHub release)'
$gooseDesktopResult = Invoke-GooseDesktopStep -NoUpgrade:$NoUpgrade
Write-Note "Goose Desktop: $gooseDesktopResult"

#--- 6. Rust toolchain (rustup only) ----------------------------------------
Write-Step 'Rust (rustup stable + components)'
$rustResult = Initialize-RustupToolchain -NoUpgrade:$NoUpgrade
Write-Note "rustup: $rustResult"

#--- 7. GooGet (built from google/googet head) ------------------------------
Write-Step 'GooGet (built from source) and the game-packages repo'
$googetResult = Invoke-GooGetStep -NoUpgrade:$NoUpgrade
Write-Note "GooGet: $googetResult"

Write-Step "game-packages GooGet packages ($($GooGetPackages.Count) entries)"
$gooResult = Invoke-GooGetPackageSet -Packages $GooGetPackages -NoUpgrade:$NoUpgrade

#--- Summary ----------------------------------------------------------------
Write-Step 'Summary'
Write-Note "winget: $($wingetResult.Installed.Count) installed now, $($wingetResult.UpdatedOrCurrent.Count) updated/current, $($wingetResult.Present.Count) presence-only, $($wingetResult.RemovedLegacy.Count) legacy removed, $($wingetResult.Deferred.Count) deferred, $($wingetResult.Failed.Count) failed"
if ($wingetResult.Deferred.Count) { Write-Note "deferred (re-run after a reboot): $($wingetResult.Deferred -join ', ')" }
if ($wingetResult.Failed.Count)   { Write-Note "failed: $($wingetResult.Failed -join ', ')" }
if ($wingetResult.HostSkipped.Count) { Write-Note "not updated (hosts this run; re-run from powershell.exe): $($wingetResult.HostSkipped -join ', ')" }
if ($script:RebootNeeded) {
    Write-Warning 'A reboot is required to finish; re-run this script afterwards to pick up anything deferred.'
}
Write-Note "native CLIs: $($nativeResult.Installed.Count) installed now, $($nativeResult.Current.Count) current, $($nativeResult.Skipped.Count) unsupported here, $($nativeResult.RetiredWinget.Count) WinGet copies removed, $($nativeResult.Failed.Count) failed"
if ($nativeResult.Failed.Count) { Write-Note "failed: $($nativeResult.Failed -join ', ')" }
Write-Note "OpenCode native installs: $($openCodeResult.Removed.Count) removed, $($openCodeResult.Failed.Count) failed"
if ($openCodeResult.Failed.Count) { Write-Note "failed: $($openCodeResult.Failed -join ', ')" }
if ($balunResult -eq 'deferred') { Write-Note 'deferred (re-run after a reboot): Balun' }
if ($googetResult -eq 'deferred') { Write-Note 'deferred (re-run once Go is installed): GooGet' }
Write-Note "game-packages: $($gooResult.Installed.Count) installed now, $($gooResult.Current.Count) current, $($gooResult.Deferred.Count) deferred, $($gooResult.Failed.Count) failed"
if ($gooResult.Deferred.Count) { Write-Note "deferred (install once enthoo answers): $($gooResult.Deferred -join ', ')" }
if ($gooResult.Failed.Count) { Write-Note "failed: $($gooResult.Failed -join ', ')" }
if ($wingetResult.Failed.Count -or $openCodeResult.Failed.Count -or $nativeResult.Failed.Count -or $rustResult -eq 'failed' -or $balunResult -eq 'failed' -or $gooseDesktopResult -eq 'failed' -or $pwshResult -eq 'failed' -or $googetResult -eq 'failed' -or $gooResult.Failed.Count) { exit 1 }
