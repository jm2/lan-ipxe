# enable-openssh-win11.ps1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Read-only: return $true when OpenSSH Server needs no change, $false
    # otherwise. Never queries DISM, so it answers in well under a second.
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

$CapabilityName = 'OpenSSH.Server~~~~0.0.1.0'
$OpenSshRegKey = 'HKLM:\SOFTWARE\OpenSSH'
$DesiredShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

# Get-WindowsCapability goes through DISM and can take minutes even when
# nothing is missing. Installing the capability is what registers the sshd
# service on the inbox binary, so that registration (with the binary present)
# already proves it is installed; DISM is only consulted when it is absent.
function Test-InboxSshdService {
    $imagePath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if (-not $imagePath) { return $false }
    $inbox = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    $registered = [Environment]::ExpandEnvironmentVariables(([string]$imagePath).Trim().Trim('"'))
    return (($registered -replace '/', '\') -ieq ($inbox -replace '/', '\')) -and (Test-Path -LiteralPath $inbox -PathType Leaf)
}

# The DISM cmdlets need the DISM COM server, which is registered only for the
# native Windows PowerShell 5.1 host: under PowerShell 7, a 32-bit host on
# 64-bit Windows, or an emulated host they fail with "Class not registered".
# Run the command in-process first, then in native Windows PowerShell
# (Sysnative reaches the 64-bit System32 from a 32-bit process).
function Get-NativeWindowsPowerShell {
    $folder = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { 'Sysnative' } else { 'System32' }
    return Join-Path $env:SystemRoot "$folder\WindowsPowerShell\v1.0\powershell.exe"
}

function Invoke-CapabilityCommand {
    param([Parameter(Mandatory = $true)][ValidateSet('Get', 'Add')][string]$Verb)
    try {
        if ($Verb -eq 'Get') { return [string](Get-WindowsCapability -Online -Name $CapabilityName).State }
        Add-WindowsCapability -Online -Name $CapabilityName | Out-Null
        return 'Installed'
    }
    catch {
        $inProcessError = $_.Exception.Message
    }
    $hostPath = Get-NativeWindowsPowerShell
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        throw "$Verb-WindowsCapability failed ($inProcessError) and Windows PowerShell was not found at $hostPath"
    }
    $command = if ($Verb -eq 'Get') {
        "`$ErrorActionPreference = 'Stop'; [string](Get-WindowsCapability -Online -Name '$CapabilityName').State"
    }
    else {
        "`$ErrorActionPreference = 'Stop'; Add-WindowsCapability -Online -Name '$CapabilityName' | Out-Null; 'Installed'"
    }
    $output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Verb-WindowsCapability failed in-process ($inProcessError) and in Windows PowerShell: $($output -join ' ')"
    }
    return ([string]($output | Select-Object -Last 1)).Trim()
}

function Test-SshdServiceState {
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    return $null -ne $service -and [string]$service.StartType -eq 'Automatic' -and [string]$service.Status -eq 'Running'
}

# The complete firewall rule, not merely its existence. This follows
# Microsoft's default all-profile scope; administrators who need a narrower
# policy can replace the rule after running this setup.
function Test-SshFirewallRule {
    param([object[]]$Rules)
    if (@($Rules).Count -ne 1) { return $false }
    $rule = $Rules[0]
    $portFilters = @($rule | Get-NetFirewallPortFilter)
    return (
        [string]$rule.Enabled -eq 'True' -and
        [string]$rule.Direction -eq 'Inbound' -and
        [string]$rule.Action -eq 'Allow' -and
        [string]$rule.Profile -eq 'Any' -and
        $portFilters.Count -eq 1 -and
        [string]$portFilters[0].Protocol -eq 'TCP' -and
        [string]$portFilters[0].LocalPort -eq '22'
    )
}

function Get-SshFirewallRule {
    return @(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)
}

function Get-SshDefaultShell {
    return (Get-ItemProperty -Path $OpenSshRegKey -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
}

if ($Test) {
    return (Test-InboxSshdService) -and (Test-SshdServiceState) -and
        (Test-SshFirewallRule -Rules (Get-SshFirewallRule)) -and
        ((Get-SshDefaultShell) -eq $DesiredShell)
}

# 1. Install the OpenSSH Server feature (DISM only when it is not evidently in place).
if (-not (Test-InboxSshdService)) {
    if ((Invoke-CapabilityCommand -Verb Get) -ne 'Installed') {
        Invoke-CapabilityCommand -Verb Add | Out-Null
    }
}

# 2. Reconcile the sshd service.
$service = Get-Service sshd -ErrorAction Stop
if ($service.StartType -ne 'Automatic') {
    Set-Service -Name sshd -StartupType Automatic
}
if ($service.Status -ne 'Running') {
    Start-Service sshd
}

# 3. Reconcile the firewall rule.
$firewallRules = Get-SshFirewallRule
if (-not (Test-SshFirewallRule -Rules $firewallRules)) {
    if ($firewallRules.Count) {
        $firewallRules | Remove-NetFirewallRule
    }
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Profile Any -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# 4. Set PowerShell as the default shell for incoming SSH connections only
# after sshd is actually installed and running.
if ((Get-Service sshd -ErrorAction SilentlyContinue).Status -ne 'Running') {
    throw 'sshd service is not running; OpenSSH Server did not converge. DefaultShell was not changed.'
}

if (!(Test-Path $OpenSshRegKey)) {
    New-Item -Path 'HKLM:\SOFTWARE' -Name 'OpenSSH' | Out-Null
}
if ((Get-SshDefaultShell) -ne $DesiredShell) {
    New-ItemProperty -Path $OpenSshRegKey -Name DefaultShell -Value $DesiredShell -PropertyType String -Force | Out-Null
}
