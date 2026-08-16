<#
    .SYNOPSIS
    Wreckfest (GOG) offline-LAN identity launcher — Windows.

    .DESCRIPTION
    GOG's Wreckfest build (2024+) ships a THQNOnline "steam_api" wrapper that derives the
    player's SteamID from a hash of GetUserName(), and GetUserName() reads the USERNAME
    environment variable of the process. Two PCs with the same Windows username therefore
    get the same ID and kick each other with "Already Logged In". This launcher starts the
    game with a stable, machine-unique USERNAME ("<player>.<4 hex>", persisted across runs)
    so every install gets a distinct ID without DLL swaps or emulators. Works on Windows
    PowerShell 5.1 and PowerShell 7+.

    .EXAMPLE
    .\Start-WreckfestLan.ps1

    .EXAMPLE
    .\Start-WreckfestLan.ps1 -Name Rincewind -Server
#>
param(
    [string]$Name,
    [string]$Dir,
    [switch]$X86,
    [switch]$Server,
    [switch]$Ask,
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'

$ConfDir = Join-Path $env:LOCALAPPDATA 'wreckfest-lan'
$ConfFile = Join-Path $ConfDir 'config.txt'

if ($Reset -and (Test-Path $ConfFile)) {
    Remove-Item $ConfFile -Force
    Write-Host "Forgot saved identity ($ConfFile)."
}

function Get-Conf([string]$Key) {
    if (-not (Test-Path $ConfFile)) { return $null }
    $line = Get-Content $ConfFile | Where-Object { $_ -like "$Key=*" } | Select-Object -Last 1
    if ($null -eq $line) { return $null }
    return $line.Substring($Key.Length + 1)
}

function Set-Conf([string]$Key, [string]$Value) {
    $lines = @()
    if (Test-Path $ConfFile) {
        $lines = @(Get-Content $ConfFile | Where-Object { $_ -notlike "$Key=*" })
    } else {
        New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
    }
    $lines += "$Key=$Value"
    Set-Content -Path $ConfFile -Value $lines
}

function Sanitize([string]$Raw) {
    $s = $Raw -replace '[^A-Za-z0-9._-]', ''
    if ($s.Length -gt 20) { $s = $s.Substring(0, 20) }
    return $s
}

$GogRegistryPaths = @(
    'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\1249986612',
    'HKLM:\SOFTWARE\GOG.com\Games\1249986612'
)
if (-not $Dir) {
    foreach ($rp in $GogRegistryPaths) {
        try {
            $p = (Get-ItemProperty -Path $rp -ErrorAction Stop).path
            if ($p -and (Test-Path (Join-Path $p 'Wreckfest_x64.exe'))) { $Dir = $p; break }
        } catch { }
    }
}
if (-not $Dir) {
    foreach ($d in @('C:\GOG Games\Wreckfest', (Get-Location).Path)) {
        if (Test-Path (Join-Path $d 'Wreckfest_x64.exe')) { $Dir = $d; break }
    }
}
if (-not $Dir -or -not (Test-Path (Join-Path $Dir 'Wreckfest_x64.exe'))) {
    throw "Wreckfest install not found; pass -Dir or install to a default GOG path."
}

$SavedName = Get-Conf 'Name'
$SavedSuffix = Get-Conf 'Suffix'

if (-not $Name) {
    if ($Ask -or -not $SavedName) {
        $default = if ($SavedName) { $SavedName } else { Sanitize $env:USERNAME }
        $Name = Read-Host "Player name [$default]"
        if (-not $Name) { $Name = $default }
    } else {
        $Name = $SavedName
    }
}
$Name = Sanitize $Name
if (-not $Name) { throw "Player name is empty after sanitizing." }

$Suffix = $SavedSuffix
if ($Suffix -notmatch '^[0-9a-fA-F]{4}$') {
    $Suffix = '{0:x4}' -f (Get-Random -Maximum 0x10000)
}

if ($Name -ne $SavedName -or $Suffix -ne $SavedSuffix) {
    Set-Conf 'Name' $Name
    Set-Conf 'Suffix' $Suffix
}

$Identity = "${Name}.${Suffix}"
$Exe = if ($X86) { 'Wreckfest.exe' } else { 'Wreckfest_x64.exe' }
$ExePath = Join-Path $Dir $Exe
if (-not (Test-Path $ExePath)) { throw "$ExePath not found." }

$env:USERNAME = $Identity
$env:WINEUSERNAME = $Identity

Write-Host "Launching $Exe as `"$Identity`" (dir: $Dir)"

if ($Server) {
    $appid = Join-Path $Dir 'steam_appid.txt'
    if (-not (Test-Path $appid)) { Set-Content -Path $appid -Value '228380' }
    $cfg = Join-Path $Dir 'server_config.cfg'
    if (-not (Test-Path $cfg)) {
        Copy-Item (Join-Path $Dir 'initial_server_config.cfg') $cfg
    }
    Start-Process -FilePath $ExePath -WorkingDirectory $Dir -ArgumentList '-s', 'server_config=server_config.cfg'
} else {
    Start-Process -FilePath $ExePath -WorkingDirectory $Dir
}
