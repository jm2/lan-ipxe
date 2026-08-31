# enable-hyperv-win11.ps1
# Enables Hyper-V through the supported Windows optional-feature interface.
# Windows 11 Home (EditionID Core*) is deliberately rejected: Microsoft does
# not support installing the Hyper-V role on Home editions.
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

$editionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
if ($editionId -like 'Core*') {
    throw "Hyper-V is not supported on Windows 11 Home (EditionID: $editionId). Upgrade to a supported edition before enabling it."
}

$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
$state = [string]$feature.State
$changed = $false
$restartNeeded = $state -eq 'EnablePending'
if ($state -ne 'Enabled' -and $state -ne 'EnablePending') {
    $result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
    $changed = $true
    $restartNeeded = [bool]$result.RestartNeeded
    $state = [string](Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop).State
    if ($state -eq 'EnablePending') {
        $restartNeeded = $true
    }
}

if ($state -ne 'Enabled' -and $state -ne 'EnablePending') {
    throw "Hyper-V did not converge after Enable-WindowsOptionalFeature (state: $state)."
}

if ($PassThru) {
    [pscustomobject]@{
        State = $state
        Changed = $changed
        RestartNeeded = $restartNeeded
    }
    return
}

if (-not $changed -and -not $restartNeeded) {
    Write-Output 'Hyper-V is already enabled. Nothing to do.'
}
elseif ($restartNeeded) {
    Write-Warning 'Hyper-V was enabled; reboot Windows to finish.'
}
else {
    Write-Output 'Hyper-V was enabled without requiring a reboot.'
}
