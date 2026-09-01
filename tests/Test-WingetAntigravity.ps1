param(
    [string]$ScriptPath = (Join-Path (Join-Path $PSScriptRoot '..') 'setup-win11-workstation.ps1')
)

$ErrorActionPreference = 'Stop'

# Load only the package declarations and reconciliation function. This keeps
# the behavior test portable while avoiding #Requires and Windows-only setup.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $ScriptPath),
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count) {
    throw "Script has parser errors: $($parseErrors -join '; ')"
}
$tokens.Count | Out-Null

$assignmentNames = @(
    'WingetPackages'
    'WingetAlwaysUpgradePackages'
    'WingetLegacyPackages'
    'WingetOkCodes'
    'WingetRebootCodes'
    'WingetDeferredCodes'
    'WingetRemoveOkCodes'
)
foreach ($assignmentName in $assignmentNames) {
    $assignmentAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq $assignmentName
    }, $true)
    if (-not $assignmentAst) { throw "$assignmentName declaration not found" }
    . ([scriptblock]::Create($assignmentAst.Extent.Text))
}

$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-WingetPackageSet'
}, $true)
if (-not $functionAst) { throw 'Invoke-WingetPackageSet function not found' }
. ([scriptblock]::Create($functionAst.Extent.Text))

function Write-Note {
    param([string]$Message)
    $Message | Out-Null
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "ASSERT: $Message (actual=[$Actual], expected=[$Expected])"
    }
}

function Assert-CollectionItem {
    param([object[]]$Collection, [object]$Expected, [string]$Message)
    if ($Collection -notcontains $Expected) {
        throw "ASSERT: $Message (missing [$Expected])"
    }
}

$currentPackages = @(
    'Anthropic.ClaudeCode'
    'Google.Antigravity'
    'Google.AntigravityCLI'
    'OpenAI.Codex'
    'SST.opencode'
    'ZedIndustries.Zed'
)
$legacyPackages = @(
    'Google.AntigravityIDE'
    'VSCodium.VSCodium'
)
foreach ($id in $currentPackages) {
    Assert-CollectionItem $WingetPackages $id "$id is in desired package set"
    Assert-CollectionItem $WingetAlwaysUpgradePackages $id "$id is refreshed every run"
}
Assert-CollectionItem $WingetPackages 'Microsoft.VisualStudioCode' 'VS Code remains the supported Windows editor fallback'
foreach ($id in $legacyPackages) {
    if ($WingetPackages -contains $id) {
        throw "ASSERT: legacy $id must not be in desired package set"
    }
    Assert-CollectionItem $WingetLegacyPackages $id "$id is explicitly purged"
}
Assert-Equal (@($WingetPackages | Select-Object -Unique).Count) $WingetPackages.Count 'desired package IDs are unique'
Assert-Equal (@($WingetAlwaysUpgradePackages | Select-Object -Unique).Count) $WingetAlwaysUpgradePackages.Count 'refresh package IDs are unique'
Assert-Equal (@($WingetLegacyPackages | Select-Object -Unique).Count) $WingetLegacyPackages.Count 'legacy package IDs are unique'

$script:WingetCalls = @()
$script:ExitCodes = @{}
function global:winget {
    $call = @($args) -join '|'
    $script:WingetCalls += $call
    $key = '{0}|{1}' -f [string]$args[0], [string]$args[2]
    if ($script:ExitCodes.ContainsKey($key)) {
        $global:LASTEXITCODE = $script:ExitCodes[$key]
    }
    else {
        $global:LASTEXITCODE = 0
    }
}

try {
    # Migration: purge both superseded products first, install a missing CLI,
    # refresh every current AI tool, and leave an ordinary package untouched.
    $script:RebootNeeded = $false
    $script:WingetCalls = @()
    $script:ExitCodes = @{
        'uninstall|Google.AntigravityIDE' = [int]0x8A150014
        'upgrade|Google.Antigravity' = [int]0x8A15002B
    }
    $focusedDesired = @('Git.Git') + $currentPackages
    $inventory = @(
        'Git.Git'
        'Anthropic.ClaudeCode'
        'Google.Antigravity'
        'Google.AntigravityIDE'
        'OpenAI.Codex'
        'SST.opencode'
        'VSCodium.VSCodium'
        'ZedIndustries.Zed'
    )
    $result = Invoke-WingetPackageSet `
        -InstalledIds $inventory `
        -DesiredIds $focusedDesired `
        -AlwaysUpgradeIds $WingetAlwaysUpgradePackages `
        -LegacyIds $WingetLegacyPackages

    $expectedCalls = @(
        'uninstall|--id|Google.AntigravityIDE|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity'
        'uninstall|--id|VSCodium.VSCodium|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity'
        'install|--id|Google.AntigravityCLI|--exact|--source|winget|--no-upgrade|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|Anthropic.ClaudeCode|--exact|--source|winget|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|Google.Antigravity|--exact|--source|winget|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|OpenAI.Codex|--exact|--source|winget|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|SST.opencode|--exact|--source|winget|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|ZedIndustries.Zed|--exact|--source|winget|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
    )
    Assert-Equal ($script:WingetCalls -join "`n") ($expectedCalls -join "`n") 'migration command sequence and exact arguments'
    Assert-Equal ($result.Present -join ',') 'Git.Git' 'ordinary installed package is skipped'
    Assert-Equal ($result.Installed -join ',') 'Google.AntigravityCLI' 'missing current CLI is installed'
    Assert-Equal ($result.UpdatedOrCurrent -join ',') 'Anthropic.ClaudeCode,Google.Antigravity,OpenAI.Codex,SST.opencode,ZedIndustries.Zed' 'installed current tools are refreshed'
    Assert-Equal ($result.RemovedLegacy -join ',') 'Google.AntigravityIDE,VSCodium.VSCodium' 'legacy packages are removed or already absent'
    Assert-Equal $result.Deferred.Count 0 'migration has no deferred operations'
    Assert-Equal $result.Failed.Count 0 'migration has no failed operations'

    # A converged second run still checks all fast-moving packages for updates,
    # without issuing any install, uninstall, or ordinary-package command.
    $script:WingetCalls = @()
    $script:ExitCodes = @{}
    $result = Invoke-WingetPackageSet `
        -InstalledIds $focusedDesired `
        -DesiredIds $focusedDesired `
        -AlwaysUpgradeIds $WingetAlwaysUpgradePackages `
        -LegacyIds $WingetLegacyPackages
    Assert-Equal $script:WingetCalls.Count $currentPackages.Count 'second run refresh count'
    foreach ($call in $script:WingetCalls) {
        if ($call -notlike 'upgrade|*') {
            throw "ASSERT: converged run issued a non-upgrade command: $call"
        }
    }
    Assert-Equal ($result.UpdatedOrCurrent -join ',') ($currentPackages -join ',') 'second run refreshes every current package'
    Assert-Equal ($result.Present -join ',') 'Git.Git' 'second run still skips ordinary installed package'

    # A failed legacy removal is visible in the final result but does not stop
    # reconciliation of the supported replacement.
    $script:WingetCalls = @()
    $script:ExitCodes = @{ 'uninstall|VSCodium.VSCodium' = 7 }
    $result = Invoke-WingetPackageSet `
        -InstalledIds @('VSCodium.VSCodium') `
        -DesiredIds @('Microsoft.VisualStudioCode') `
        -LegacyIds @('VSCodium.VSCodium')
    Assert-Equal ($result.Failed -join ',') 'uninstall VSCodium.VSCodium' 'failed purge is reported'
    Assert-Equal ($result.Installed -join ',') 'Microsoft.VisualStudioCode' 'replacement still installs after a failed purge'
}
finally {
    Remove-Item -Path Function:\global:winget -ErrorAction SilentlyContinue
}

Write-Output 'ALL WINGET MIGRATION ASSERTIONS PASSED'
