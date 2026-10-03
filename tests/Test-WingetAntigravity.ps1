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
    'NativeCliTools'
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

foreach ($functionName in @('Resolve-LatestPythonWingetPackageId', 'Invoke-WingetPackageSet',
        'Get-NativeCliPath', 'Invoke-NativeCliSet')) {
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
    'SST.opencode'
    'ZedIndustries.Zed'
)
# Self-updating native installs replace these WinGet packages.
$nativeReplacedPackages = @{
    'Anthropic.ClaudeCode' = 'https://claude.ai/install.ps1'
    'OpenAI.Codex' = 'https://chatgpt.com/codex/install.ps1'
    'Google.AntigravityCLI' = 'https://antigravity.google/cli/install.ps1'
}
foreach ($id in $nativeReplacedPackages.Keys) {
    if ($WingetPackages -contains $id -or $WingetLegacyPackages -contains $id) {
        throw "ASSERT: $id must be retired by the native step, not managed by WinGet"
    }
    $tool = @($NativeCliTools | Where-Object { $_.WingetId -eq $id })
    Assert-Equal $tool.Count 1 "$id has exactly one native replacement"
    Assert-Equal $tool[0].Installer $nativeReplacedPackages[$id] "$id is replaced by its vendor's official installer"
}
# The Antigravity app updates itself; WinGet only installs it when missing.
Assert-CollectionItem $WingetPackages 'Google.Antigravity' 'Antigravity app remains in the desired package set'
Assert-CollectionItem $WingetPresenceOnlyPackages 'Google.Antigravity' 'Antigravity app is presence-only so its own updater owns it'
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
Assert-Equal ($WingetPresenceOnlyPackages -join ',') 'Google.Antigravity,Ookla.Speedtest.CLI' 'only the self-updating Antigravity app and the pinned Speedtest CLI are presence-only'
foreach ($id in $WingetPresenceOnlyPackages) {
    Assert-CollectionItem $WingetPackages $id "$id presence-only exemption belongs to the desired package set"
}
foreach ($id in $WingetPackages) {
    if ($id -notin @('Google.Antigravity', 'Ookla.Speedtest.CLI') -and $WingetPresenceOnlyPackages -contains $id) {
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
    }
    $focusedDesired = @('Git.Git', 'Ookla.Speedtest.CLI', 'Google.Antigravity', 'Microsoft.VisualStudioCode') + $currentPackages
    $inventory = @(
        'Git.Git'
        'Ookla.Speedtest.CLI'
        'Google.Antigravity'
        'Google.AntigravityIDE'
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
        'install|--id|Microsoft.VisualStudioCode|--exact|--source|winget|--no-upgrade|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|Git.Git|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|SST.opencode|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|ZedIndustries.Zed|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
    )
    Assert-Equal ($script:WingetCalls -join "`n") ($expectedCalls -join "`n") 'migration command sequence and exact arguments'
    Assert-Equal ($result.Present -join ',') 'Ookla.Speedtest.CLI,Google.Antigravity' 'installed Speedtest CLI and self-updating Antigravity app are presence-only'
    Assert-Equal ($result.Installed -join ',') 'Microsoft.VisualStudioCode' 'missing desired package is installed'
    Assert-Equal ($result.UpdatedOrCurrent -join ',') 'Git.Git,SST.opencode,ZedIndustries.Zed' 'ordinary and current tools are refreshed, including an accepted no-update result'
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
    Assert-Equal $script:WingetCalls.Count ($currentPackages.Count + 2) 'second run refresh count'
    foreach ($call in $script:WingetCalls) {
        if ($call -notlike 'upgrade|*') {
            throw "ASSERT: converged run issued a non-upgrade command: $call"
        }
    }
    Assert-Equal ($result.UpdatedOrCurrent -join ',') ((@('Git.Git', 'Microsoft.VisualStudioCode') + $currentPackages) -join ',') 'second run refreshes ordinary and current packages'
    Assert-Equal ($result.Present -join ',') 'Ookla.Speedtest.CLI,Google.Antigravity' 'second run still skips only the presence-only packages'

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

    # Native CLIs: each official installer runs, the command is verified, and
    # only then is the WinGet copy it replaces uninstalled. A failed install
    # keeps the WinGet copy.
    $nativeRoot = Join-Path ([IO.Path]::GetTempPath()) ("native-cli-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    $savedRoots = @{ USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA }
    $env:USERPROFILE = Join-Path $nativeRoot 'profile'
    $env:LOCALAPPDATA = Join-Path $nativeRoot 'local'
    $script:InstallerRuns = @()
    $script:FailInstaller = ''
    function Invoke-NativeCliInstaller {
        param([hashtable]$Tool)
        $script:InstallerRuns += $Tool.Name
        if ($Tool.Name -eq $script:FailInstaller) { throw 'download failed' }
        $path = Get-NativeCliPath -Tool $Tool
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-Content -LiteralPath $path -Value 'native'
    }
    function Test-NativeCliCommand {
        param([string]$Path)
        return (Get-Content -Raw -LiteralPath $Path).Trim() -eq 'native'
    }
    try {
        $script:WingetCalls = @()
        $script:ExitCodes = @{}
        $script:FailInstaller = 'Codex CLI'
        $native = Invoke-NativeCliSet -InstalledIds @('Anthropic.ClaudeCode', 'OpenAI.Codex', 'Git.Git') 3>$null
        Assert-Equal ($script:InstallerRuns -join ',') 'Claude Code,Codex CLI,Antigravity CLI' 'every native installer runs'
        Assert-Equal ($script:WingetCalls -join "`n") 'uninstall|--id|Anthropic.ClaudeCode|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity' 'only the verified replacement retires its WinGet copy'
        Assert-Equal ($native.RetiredWinget -join ',') 'Anthropic.ClaudeCode' 'retired WinGet copies are reported'
        Assert-Equal ($native.Installed -join ',') 'Claude Code,Antigravity CLI' 'new native installs are reported'
        Assert-Equal ($native.Failed -join ',') 'install Codex CLI' 'a failed native install is reported'

        # -NoUpgrade keeps an existing native command without running its installer.
        $script:InstallerRuns = @()
        $script:WingetCalls = @()
        $script:FailInstaller = ''
        $native = Invoke-NativeCliSet -InstalledIds @() -NoUpgrade
        Assert-Equal ($script:InstallerRuns -join ',') 'Codex CLI' '-NoUpgrade runs only the missing installer'
        Assert-Equal ($native.Current -join ',') 'Claude Code,Antigravity CLI' '-NoUpgrade keeps present native commands'
        Assert-Equal $script:WingetCalls.Count 0 'no WinGet copies remain to retire'
    }
    finally {
        $env:USERPROFILE = $savedRoots.USERPROFILE
        $env:LOCALAPPDATA = $savedRoots.LOCALAPPDATA
        Remove-Item -LiteralPath $nativeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -Path Function:\global:winget -ErrorAction SilentlyContinue
}

Write-Output 'ALL WINGET MIGRATION ASSERTIONS PASSED'
