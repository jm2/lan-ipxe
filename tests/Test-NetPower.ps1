#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path $PSScriptRoot -Parent) 'win11pxe/DisableNetPower.ps1'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "net-power-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $scratch | Out-Null
$netPowerState = @{ Changes = @(); Settings = @{}; FailQuery = $false; FailTask = $false; TaskCalls = 0 }

function Get-NetAdapter { [CmdletBinding()]param() [pscustomobject]@{ Name = 'Boot NIC' } }
function Get-NetAdapterPowerManagement {
    [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($netPowerState.failQuery) { throw "Cannot read $($InputObject.Name)" }
        [pscustomobject]$netPowerState.settings
    }
}
function Set-NetAdapterPowerManagement {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mock only; validates the no-restart contract without changing adapters.')]
    [CmdletBinding()]param(
        [Parameter(ValueFromPipeline)]$InputObject,
        [ValidateSet('Enabled', 'Disabled')][string]$SelectiveSuspend,
        [ValidateSet('Enabled', 'Disabled')][string]$DeviceSleepOnDisconnect,
        [switch]$NoRestart
    )
    process {
        if (-not $NoRestart) { throw "Attempted to restart $($InputObject.Name)" }
        if ($SelectiveSuspend) { $netPowerState.settings.SelectiveSuspend = $SelectiveSuspend }
        if ($DeviceSleepOnDisconnect) { $netPowerState.settings.DeviceSleepOnDisconnect = $DeviceSleepOnDisconnect }
        $netPowerState.changes += @{} + $PSBoundParameters
    }
}
function New-ScheduledTaskAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mock only; returns task data without registering a task.')]
    param($Execute, $Argument)
    [pscustomobject]@{ Execute = $Execute; Argument = $Argument }
}
function New-ScheduledTaskTrigger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mock only; returns trigger data without registering a task.')]
    param([switch]$AtStartup)
    if (-not $AtStartup) { throw 'Expected startup trigger' }
    'startup'
}
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $User, $RunLevel, [switch]$Force)
    $netPowerState.taskCalls++
    if ($TaskName -ne 'DisableNetPower' -or $Trigger -ne 'startup' -or $User -ne 'SYSTEM' -or $RunLevel -ne 'Highest' -or -not $Force) { throw 'Incorrect task registration' }
    if ($Action.Argument -notlike '*-File "*DisableNetPower.ps1"' -or $Action.Execute -notlike '*powershell.exe') { throw 'Incorrect task command/quoting' }
    if ($netPowerState.failTask) { throw 'Task registration denied' }
}
function Assert-NetPower {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

try {
    $log = Join-Path $scratch 'runtime.log'
    $netPowerState.settings = @{ SelectiveSuspend = 'Enabled'; DeviceSleepOnDisconnect = 'Enabled' }
    & $helper -LogPath $log -InstallStartupTask
    Assert-NetPower ($netPowerState.taskCalls -eq 1) "Startup task installed: $(Get-Content -Raw $log -ErrorAction SilentlyContinue)"
    Assert-NetPower ($netPowerState.changes.Count -eq 1 -and $netPowerState.changes[0].NoRestart) 'Sleep features changed without NIC restart'
    & $helper -LogPath $log
    Assert-NetPower ($netPowerState.changes.Count -eq 1 -and $netPowerState.taskCalls -eq 1) 'Second startup is idempotent'

    $netPowerState.settings = @{ SelectiveSuspend = 'Unsupported'; DeviceSleepOnDisconnect = 'Enabled' }
    & $helper -LogPath $log
    Assert-NetPower (-not $netPowerState.changes[-1].ContainsKey('SelectiveSuspend')) 'Unsupported setting omitted'

    $netPowerState.failQuery = $true
    $global:LASTEXITCODE = 0
    & $helper -LogPath $log
    Assert-NetPower ($LASTEXITCODE -eq 1) 'Query failure returns nonzero'
    Assert-NetPower ((Get-Content -Raw $log) -like '*Cannot read Boot NIC*') 'Query failure persisted'
    $netPowerState.failQuery = $false

    $netPowerState.failTask = $true
    $netPowerState.settings = @{ SelectiveSuspend = 'Enabled'; DeviceSleepOnDisconnect = 'Disabled' }
    $global:LASTEXITCODE = 0
    & $helper -LogPath $log -InstallStartupTask
    Assert-NetPower ($LASTEXITCODE -eq 1) 'Registration failure returns nonzero'
    Assert-NetPower ((Get-Content -Raw $log) -like '*Task registration denied*') 'Registration failure persisted'
    Assert-NetPower ($netPowerState.settings.SelectiveSuspend -eq 'Disabled') 'Registration failure does not skip power settings'
    Write-Output 'NIC power management regression tests: PASS'
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
# Expected helper failures must not become the GitHub PowerShell runner's exit
# status after every assertion passes. An assertion throw never reaches here.
$global:LASTEXITCODE = 0
