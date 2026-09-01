# enable-openssh-win11.ps1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# 1. Install the OpenSSH Server feature.
$capability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($capability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
}

# 2. Reconcile the sshd service.
$service = Get-Service sshd -ErrorAction Stop
if ($service.StartType -ne 'Automatic') {
    Set-Service -Name sshd -StartupType Automatic
}
if ($service.Status -ne 'Running') {
    Start-Service sshd
}

# 3. Reconcile the complete firewall rule, not merely its existence. This
# follows Microsoft's default all-profile scope; administrators who need a
# narrower policy can replace the rule after running this setup.
$firewallRules = @(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)
$firewallRuleValid = $firewallRules.Count -eq 1
if ($firewallRuleValid) {
    $firewallRule = $firewallRules[0]
    $portFilters = @($firewallRule | Get-NetFirewallPortFilter)
    $firewallRuleValid = (
        [string]$firewallRule.Enabled -eq 'True' -and
        [string]$firewallRule.Direction -eq 'Inbound' -and
        [string]$firewallRule.Action -eq 'Allow' -and
        [string]$firewallRule.Profile -eq 'Any' -and
        $portFilters.Count -eq 1 -and
        [string]$portFilters[0].Protocol -eq 'TCP' -and
        [string]$portFilters[0].LocalPort -eq '22'
    )
}
if (-not $firewallRuleValid) {
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

$OpenSshRegKey = 'HKLM:\SOFTWARE\OpenSSH'
if (!(Test-Path $OpenSshRegKey)) {
    New-Item -Path 'HKLM:\SOFTWARE' -Name 'OpenSSH' | Out-Null
}
$desiredShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$currentShell = (Get-ItemProperty -Path $OpenSshRegKey -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if ($currentShell -ne $desiredShell) {
    New-ItemProperty -Path $OpenSshRegKey -Name DefaultShell -Value $desiredShell -PropertyType String -Force | Out-Null
}
