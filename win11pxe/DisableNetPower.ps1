#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LogPath = "$env:SystemRoot\Logs\DisableNetPower.log",
    [switch]$InstallStartupTask
)

$ErrorActionPreference = 'Stop'
$failed = $false
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
    if ($InstallStartupTask) {
        try {
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            Register-ScheduledTask -TaskName 'DisableNetPower' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest -Force | Out-Null
        }
        catch {
            $failed = $true
            Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) Startup task registration failed: $($_.Exception.Message)"
        }
    }
    foreach ($adapter in (Get-NetAdapter -ErrorAction Stop)) {
        try {
            $power = $adapter | Get-NetAdapterPowerManagement -ErrorAction Stop
            $changes = @{}
            foreach ($feature in 'SelectiveSuspend', 'DeviceSleepOnDisconnect') {
                if ([string]$power.$feature -eq 'Enabled') { $changes[$feature] = 'Disabled' }
            }
            if ($changes.Count) {
                # A live iSCSI boot NIC must never be restarted to apply a setting.
                $adapter | Set-NetAdapterPowerManagement @changes -NoRestart -ErrorAction Stop
                Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $($adapter.Name): disabled $($changes.Keys -join ', '); no restart requested."
            }
        }
        catch {
            $failed = $true
            Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $($adapter.Name): $($_.Exception.Message)"
        }
    }
}
catch {
    $failed = $true
    Write-Warning "NIC power management failed: $($_.Exception.Message)"
}
if ($failed) { exit 1 }
