# enable-openssh-win11.ps1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# 1. Install the OpenSSH Server feature
$capability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($capability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
}

# 2. Start the sshd service
Start-Service sshd

# 3. Set the sshd service to start automatically on boot
Set-Service -Name sshd -StartupType 'Automatic'

# 4. Confirm the Firewall rule is active (usually created automatically during install)
if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue | Select-Object Name, Enabled)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# 5. Set PowerShell as the default shell for incoming SSH connections.
#    Only do this once sshd is actually installed AND running, so a failed
#    capability install can't leave the DefaultShell value set (which the
#    calling manifest uses as its completion guard).
if ((Get-Service sshd -ErrorAction SilentlyContinue).Status -ne 'Running') {
    Write-Error "sshd service is not running; OpenSSH Server install did not complete. Not setting DefaultShell."
    exit 1
}

$OpenSshRegKey = "HKLM:\SOFTWARE\OpenSSH"
if (!(Test-Path $OpenSshRegKey)) {
    New-Item -Path "HKLM:\SOFTWARE" -Name "OpenSSH" | Out-Null
}
New-ItemProperty -Path $OpenSshRegKey -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
