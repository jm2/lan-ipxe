param(
    [string]$HelperPath = (Join-Path (Join-Path $PSScriptRoot '..') 'enable-hyperv-win11.ps1')
)

$ErrorActionPreference = 'Stop'

# Run the real helper body with only its administrator #Requires guard removed. The
# Windows feature cmdlets are mocked below, so this can exercise the state
# machine on the Ubuntu PowerShell CI runner.
$helperSource = @(
    Get-Content -LiteralPath (Resolve-Path -LiteralPath $HelperPath) |
        Where-Object { $_ -notmatch '^#Requires\s' }
) -join [Environment]::NewLine
$helper = [scriptblock]::Create($helperSource)

$script:EditionId = 'Professional'
$script:FeatureStates = @()
$script:FeatureQueryIndex = 0
$script:EnableRestartNeeded = $false
$script:EnableCalls = 0

function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$Path, [string]$Name)
    [pscustomobject]@{ EditionID = $script:EditionId }
}

function Get-WindowsOptionalFeature {
    [CmdletBinding()]
    param([switch]$Online, [string]$FeatureName)
    if ($script:FeatureQueryIndex -ge $script:FeatureStates.Count) {
        throw 'mock feature-state queue exhausted'
    }
    $state = $script:FeatureStates[$script:FeatureQueryIndex]
    $script:FeatureQueryIndex += 1
    [pscustomobject]@{ State = $state }
}

function Enable-WindowsOptionalFeature {
    [CmdletBinding()]
    param(
        [switch]$Online,
        [string]$FeatureName,
        [switch]$All,
        [switch]$NoRestart
    )
    $script:EnableCalls += 1
    [pscustomobject]@{ RestartNeeded = $script:EnableRestartNeeded }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "ASSERT: $Message (actual=[$Actual], expected=[$Expected])"
    }
}

function Invoke-HyperVCase {
    param(
        [string]$Name,
        [string]$Edition,
        [string[]]$States,
        [bool]$EnableRestart,
        [bool]$ShouldThrow,
        [string]$ExpectedState = '',
        [bool]$ExpectedChanged = $false,
        [bool]$ExpectedRestart = $false,
        [int]$ExpectedEnableCalls = 0
    )
    $script:EditionId = $Edition
    $script:FeatureStates = @($States)
    $script:FeatureQueryIndex = 0
    $script:EnableRestartNeeded = $EnableRestart
    $script:EnableCalls = 0
    $caught = $null
    $result = @()
    try {
        $result = @(& $helper -PassThru)
    }
    catch {
        $caught = $_
    }

    if ($ShouldThrow -and -not $caught) { throw "ASSERT: $Name should throw" }
    if (-not $ShouldThrow -and $caught) { throw "ASSERT: $Name unexpectedly threw: $caught" }
    Assert-Equal $script:EnableCalls $ExpectedEnableCalls "$Name enable calls"
    if (-not $ShouldThrow) {
        Assert-Equal $result.Count 1 "$Name status-result count"
        Assert-Equal $result[0].State $ExpectedState "$Name state"
        Assert-Equal $result[0].Changed $ExpectedChanged "$Name changed"
        Assert-Equal $result[0].RestartNeeded $ExpectedRestart "$Name restart signal"
    }
    [pscustomobject]@{
        Scenario = $Name
        Outcome = if ($caught) { 'threw' } else { 'returned' }
        State = if ($result.Count) { $result[0].State } else { '' }
        Restart = if ($result.Count) { $result[0].RestartNeeded } else { '' }
    }
}

$results = @(
    Invoke-HyperVCase already-enabled Professional @('Enabled') $false $false 'Enabled' $false $false 0
    Invoke-HyperVCase already-pending Professional @('EnablePending') $false $false 'EnablePending' $false $true 0
    Invoke-HyperVCase enabled-restart Professional @('Disabled', 'Enabled') $true $false 'Enabled' $true $true 1
    Invoke-HyperVCase enabled-no-restart Professional @('Disabled', 'Enabled') $false $false 'Enabled' $true $false 1
    Invoke-HyperVCase result-pending Professional @('Disabled', 'EnablePending') $false $false 'EnablePending' $true $true 1
    Invoke-HyperVCase home-rejected Core @() $false $true '' $false $false 0
    Invoke-HyperVCase failed-convergence Professional @('Disabled', 'Disabled') $false $true '' $false $false 1
)

$results | Format-Table -AutoSize
Write-Output 'ALL ASSERTIONS PASSED'

$setupPath = Join-Path (Join-Path $PSScriptRoot '..') 'setup-win11-workstation.ps1'
$setupSource = Get-Content -Raw -LiteralPath $setupPath
if ($setupSource -notmatch "enable-hyperv-win11\.ps1'\) -PassThru") {
    throw 'ASSERT: workstation setup does not request the helper status result'
}
if ($setupSource -notmatch '\$hyperVResult\[0\]\.RestartNeeded') {
    throw 'ASSERT: workstation setup does not consume the helper restart signal'
}
Write-Output 'CALLER CONTRACT ASSERTIONS PASSED'
