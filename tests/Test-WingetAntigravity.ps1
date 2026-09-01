param(
    [string]$ScriptPath = (Join-Path (Join-Path $PSScriptRoot '..') 'setup-win11-workstation.ps1')
)

$ErrorActionPreference = 'Stop'

# Load only the package declarations and WinGet helper functions. This keeps
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
    'WingetPresenceOnlyPackages'
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

foreach ($functionName in @('Resolve-LatestPythonWingetPackageId', 'Invoke-WingetPackageSet')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if (-not $functionAst) { throw "$functionName function not found" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

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
    if ($WingetPresenceOnlyPackages -contains $id) {
        throw "ASSERT: current developer package $id must be refreshed every run"
    }
}
Assert-CollectionItem $WingetPackages 'Microsoft.VisualStudioCode' 'VS Code remains the supported Windows editor fallback'
if (@($WingetPackages | Where-Object { $_ -like 'Python.Python.3.*' }).Count -ne 0) {
    throw 'ASSERT: desired package set retains a hard-coded Python 3 minor channel'
}
$scriptText = Get-Content -Raw -LiteralPath $ScriptPath
if ($scriptText -notmatch '(?m)^\$latestPythonPackageId = Resolve-LatestPythonWingetPackageId\r?$' -or
    $scriptText -notmatch '(?m)^\$WingetPackages \+= \$latestPythonPackageId\r?$') {
    throw 'ASSERT: dynamically resolved Python channel is not added to the desired WinGet set'
}
Assert-Equal ($WingetPresenceOnlyPackages -join ',') 'Ookla.Speedtest.CLI' 'Speedtest CLI is the only presence-only package'
foreach ($id in $WingetPresenceOnlyPackages) {
    Assert-CollectionItem $WingetPackages $id "$id presence-only exemption belongs to the desired package set"
}
foreach ($id in $WingetPackages) {
    if ($id -ne 'Ookla.Speedtest.CLI' -and $WingetPresenceOnlyPackages -contains $id) {
        throw "ASSERT: ordinary desired package $id was unexpectedly exempted from upgrades"
    }
}
foreach ($id in $legacyPackages) {
    if ($WingetPackages -contains $id) {
        throw "ASSERT: legacy $id must not be in desired package set"
    }
    Assert-CollectionItem $WingetLegacyPackages $id "$id is explicitly purged"
}
Assert-Equal (@($WingetPackages | Select-Object -Unique).Count) $WingetPackages.Count 'desired package IDs are unique'
Assert-Equal (@($WingetPresenceOnlyPackages | Select-Object -Unique).Count) $WingetPresenceOnlyPackages.Count 'presence-only package IDs are unique'
Assert-Equal (@($WingetLegacyPackages | Select-Object -Unique).Count) $WingetLegacyPackages.Count 'legacy package IDs are unique'

$script:WingetCalls = @()
$script:ExitCodes = @{}
$script:WingetSearchOutput = @()
$script:WingetSearchExitCode = 0
function global:winget {
    $call = @($args) -join '|'
    $script:WingetCalls += $call
    if ($args[0] -eq 'search') {
        $global:LASTEXITCODE = $script:WingetSearchExitCode
        return $script:WingetSearchOutput
    }
    $key = '{0}|{1}' -f [string]$args[0], [string]$args[2]
    if ($script:ExitCodes.ContainsKey($key)) {
        $global:LASTEXITCODE = $script:ExitCodes[$key]
    }
    else {
        $global:LASTEXITCODE = 0
    }
}

try {
    # WinGet's Python packages use one ID per minor release. Search output is
    # intentionally treated as unstructured except for exact package-ID tokens.
    $script:WingetCalls = @()
    $script:WingetSearchExitCode = 0
    $script:WingetSearchOutput = @(
        'Name          Id                          Version Source'
        '-------------------------------------------------------'
        'Python 3.9    Python.Python.3.9           3.9.99  winget'
        'Python 3.14   Python.Python.3.14          3.14.2  winget'
        'Duplicate     Python.Python.3.14          3.14.2  winget'
        'Preview       Python.Python.3.99-preview  3.99.0  winget'
        'Free threaded Python.Python.3.14.FreeThreaded 3.14.2 winget'
    )
    $resolvedPython = Resolve-LatestPythonWingetPackageId
    Assert-Equal $resolvedPython 'Python.Python.3.14' 'highest stable Python minor ID is selected numerically'
    Assert-Equal ($script:WingetCalls -join "`n") 'search|--id|Python.Python.3.|--source|winget|--count|1000|--accept-source-agreements|--disable-interactivity' 'Python resolver uses the native WinGet source'

    $script:WingetSearchOutput = @('no matching package IDs')
    $noPythonRejected = $false
    try { Resolve-LatestPythonWingetPackageId | Out-Null }
    catch { $noPythonRejected = $_.Exception.Message -eq 'winget returned no stable Python.Python.3.N package IDs' }
    Assert-Equal $noPythonRejected $true 'empty Python search result is rejected'

    $script:WingetSearchExitCode = 7
    $failedSearchRejected = $false
    try { Resolve-LatestPythonWingetPackageId | Out-Null }
    catch { $failedSearchRejected = $_.Exception.Message -like 'winget could not resolve the latest Python 3 package ID*' }
    Assert-Equal $failedSearchRejected $true 'failed Python WinGet search is rejected'

    # Migration: purge both superseded products first, install a missing CLI,
    # refresh developer and ordinary packages, and leave only the deliberately
    # fixed Speedtest CLI untouched.
    $script:RebootNeeded = $false
    $script:WingetCalls = @()
    $script:WingetSearchExitCode = 0
    $script:ExitCodes = @{
        'uninstall|Google.AntigravityIDE' = [int]0x8A150014
        'upgrade|Git.Git' = [int]0x8A15002B
        'upgrade|Google.Antigravity' = [int]0x8A15002B
    }
    $focusedDesired = @('Git.Git', 'Ookla.Speedtest.CLI') + $currentPackages
    $inventory = @(
        'Git.Git'
        'Ookla.Speedtest.CLI'
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
        -PresenceOnlyIds $WingetPresenceOnlyPackages `
        -LegacyIds $WingetLegacyPackages

    $expectedCalls = @(
        'uninstall|--id|Google.AntigravityIDE|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity'
        'uninstall|--id|VSCodium.VSCodium|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity'
        'install|--id|Google.AntigravityCLI|--exact|--source|winget|--no-upgrade|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|Git.Git|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|Anthropic.ClaudeCode|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|Google.Antigravity|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|OpenAI.Codex|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|SST.opencode|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|ZedIndustries.Zed|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
    )
    Assert-Equal ($script:WingetCalls -join "`n") ($expectedCalls -join "`n") 'migration command sequence and exact arguments'
    Assert-Equal ($result.Present -join ',') 'Ookla.Speedtest.CLI' 'installed Speedtest CLI remains presence-only'
    Assert-Equal ($result.Installed -join ',') 'Google.AntigravityCLI' 'missing current CLI is installed'
    Assert-Equal ($result.UpdatedOrCurrent -join ',') 'Git.Git,Anthropic.ClaudeCode,Google.Antigravity,OpenAI.Codex,SST.opencode,ZedIndustries.Zed' 'ordinary and current tools are refreshed, including an accepted no-update result'
    Assert-Equal ($result.RemovedLegacy -join ',') 'Google.AntigravityIDE,VSCodium.VSCodium' 'legacy packages are removed or already absent'
    Assert-Equal $result.Deferred.Count 0 'migration has no deferred operations'
    Assert-Equal $result.Failed.Count 0 'migration has no failed operations'

    # A converged second run checks every desired package except the explicit
    # presence-only exemption, without issuing an install or uninstall.
    $script:WingetCalls = @()
    $script:ExitCodes = @{}
    $result = Invoke-WingetPackageSet `
        -InstalledIds $focusedDesired `
        -DesiredIds $focusedDesired `
        -PresenceOnlyIds $WingetPresenceOnlyPackages `
        -LegacyIds $WingetLegacyPackages
    Assert-Equal $script:WingetCalls.Count ($currentPackages.Count + 1) 'second run refresh count'
    foreach ($call in $script:WingetCalls) {
        if ($call -notlike 'upgrade|*') {
            throw "ASSERT: converged run issued a non-upgrade command: $call"
        }
    }
    Assert-Equal ($result.UpdatedOrCurrent -join ',') ((@('Git.Git') + $currentPackages) -join ',') 'second run refreshes ordinary and current packages'
    Assert-Equal ($result.Present -join ',') 'Ookla.Speedtest.CLI' 'second run still skips only the fixed Speedtest CLI'

    # Presence-only affects only an installed package; a missing exempt package
    # still receives the same exact-ID install as the rest of the desired set.
    $script:WingetCalls = @()
    $script:ExitCodes = @{}
    $result = Invoke-WingetPackageSet `
        -InstalledIds @('Example.Unrelated') `
        -DesiredIds @('Ookla.Speedtest.CLI') `
        -PresenceOnlyIds @('Ookla.Speedtest.CLI')
    Assert-Equal ($script:WingetCalls -join "`n") 'install|--id|Ookla.Speedtest.CLI|--exact|--source|winget|--no-upgrade|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity' 'missing Speedtest CLI is installed exactly'
    Assert-Equal ($result.Installed -join ',') 'Ookla.Speedtest.CLI' 'missing presence-only package installs'

    # A typo in the exemption list cannot silently suppress updates for a
    # package outside the declared desired set.
    $invalidExemptionRejected = $false
    try {
        Invoke-WingetPackageSet `
            -InstalledIds @('Example.Unrelated') `
            -DesiredIds @('Git.Git') `
            -PresenceOnlyIds @('Example.NotDesired') | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike 'Presence-only WinGet package is not in the desired set:*') {
            throw
        }
        $invalidExemptionRejected = $true
    }
    Assert-Equal $invalidExemptionRejected $true 'invalid presence-only exemption is rejected'

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
