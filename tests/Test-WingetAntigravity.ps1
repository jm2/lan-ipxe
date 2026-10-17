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
    'GooseRepo'
    'GooseDesktopAsset'
    'GooseDesktopArchitectures'
    'GooseDesktopMarkerName'
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
        'Get-NativeProcessorArchitecture', 'Test-NativeCliSupported', 'Get-NativeCliPath', 'Invoke-NativeCliSet',
        'Get-GooseDesktopRoot', 'Get-GooseDesktopInstall', 'Select-GooseDesktopAsset', 'Find-GooseDesktopAppDirectory', 'Invoke-GooseDesktopStep')) {
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
    'charmbracelet.crush'
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
# goose comes from its official installer only, on the x64 builds upstream ships;
# it replaces no WinGet package.
$goose = @($NativeCliTools | Where-Object { $_.Name -eq 'goose CLI' })
Assert-Equal $goose.Count 1 'goose CLI has exactly one native entry'
Assert-Equal $goose[0].Installer 'https://raw.githubusercontent.com/aaif-goose/goose/main/download_cli.ps1' 'goose uses its official PowerShell installer'
Assert-Equal $goose[0].RelativePath '.local\bin\goose.exe' 'goose lands in its installer default directory'
Assert-Equal ($goose[0].Architectures -join ',') 'AMD64' 'goose is gated to the x64 builds upstream publishes'
Assert-Equal $goose[0].Environment.CONFIGURE 'false' 'goose installer never starts interactive configuration'
Assert-Equal $goose[0].AddToUserPath $true 'goose bin directory is put on the user PATH'
if ($goose[0].WingetId) { throw 'ASSERT: goose has no WinGet package to retire' }
Assert-Equal ($GooseDesktopArchitectures -join ',') 'AMD64' 'Goose Desktop is gated to the x64 zip upstream publishes'
foreach ($id in @($WingetPackages + $WingetLegacyPackages)) {
    if ($id -match '(?i)goose') { throw "ASSERT: Goose must not be managed through WinGet ($id)" }
}
# The Antigravity app updates itself; WinGet only installs it when missing.
Assert-CollectionItem $WingetPackages 'Google.Antigravity' 'Antigravity app remains in the desired package set'
Assert-CollectionItem $WingetPresenceOnlyPackages 'Google.Antigravity' 'Antigravity app is presence-only so its own updater owns it'
$legacyPackages = @(
    'Google.AntigravityIDE'
    'VSCodium.VSCodium'
    'SST.opencode'
    'SST.OpenCodeDesktop'
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
        'SST.OpenCodeDesktop'
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
        'uninstall|--id|SST.opencode|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity'
        'uninstall|--id|SST.OpenCodeDesktop|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity'
        'install|--id|Microsoft.VisualStudioCode|--exact|--source|winget|--no-upgrade|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'install|--id|charmbracelet.crush|--exact|--source|winget|--no-upgrade|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|Git.Git|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
        'upgrade|--id|ZedIndustries.Zed|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity'
    )
    Assert-Equal ($script:WingetCalls -join "`n") ($expectedCalls -join "`n") 'migration command sequence and exact arguments'
    Assert-Equal ($result.Present -join ',') 'Ookla.Speedtest.CLI,Google.Antigravity' 'installed Speedtest CLI and self-updating Antigravity app are presence-only'
    Assert-Equal ($result.Installed -join ',') 'Microsoft.VisualStudioCode,charmbracelet.crush' 'missing desired packages are installed'
    Assert-Equal ($result.UpdatedOrCurrent -join ',') 'Git.Git,ZedIndustries.Zed' 'ordinary and current tools are refreshed, including an accepted no-update result'
    Assert-Equal ($result.RemovedLegacy -join ',') 'Google.AntigravityIDE,VSCodium.VSCodium,SST.opencode,SST.OpenCodeDesktop' 'legacy packages, including OpenCode CLI and desktop, are removed or already absent'
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
    $savedRoots = @{
        USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA
        PROCESSOR_ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE; PROCESSOR_ARCHITEW6432 = $env:PROCESSOR_ARCHITEW6432
    }
    $env:USERPROFILE = Join-Path $nativeRoot 'profile'
    $env:LOCALAPPDATA = Join-Path $nativeRoot 'local'
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:PROCESSOR_ARCHITEW6432 = $null
    $script:PathAdds = @()
    function Add-UserPathEntry {
        param([string]$Directory)
        $script:PathAdds += $Directory
        return $true
    }
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
        Assert-Equal ($script:InstallerRuns -join ',') 'Claude Code,Codex CLI,Antigravity CLI,goose CLI' 'every native installer runs on x64'
        Assert-Equal ($script:WingetCalls -join "`n") 'uninstall|--id|Anthropic.ClaudeCode|--exact|--source|winget|--silent|--accept-source-agreements|--disable-interactivity' 'only the verified replacement retires its WinGet copy'
        Assert-Equal ($native.RetiredWinget -join ',') 'Anthropic.ClaudeCode' 'retired WinGet copies are reported'
        Assert-Equal ($native.Installed -join ',') 'Claude Code,Antigravity CLI,goose CLI' 'new native installs are reported'
        Assert-Equal ($native.Failed -join ',') 'install Codex CLI' 'a failed native install is reported'
        Assert-Equal $native.Skipped.Count 0 'nothing is skipped on x64'
        Assert-Equal ($script:PathAdds -join ',') (Join-Path (Join-Path $env:USERPROFILE '.local') 'bin') 'only goose asks for its bin directory on the user PATH'

        # -NoUpgrade keeps an existing native command without running its installer.
        $script:InstallerRuns = @()
        $script:WingetCalls = @()
        $script:FailInstaller = ''
        $native = Invoke-NativeCliSet -InstalledIds @() -NoUpgrade
        Assert-Equal ($script:InstallerRuns -join ',') 'Codex CLI' '-NoUpgrade runs only the missing installer'
        Assert-Equal ($native.Current -join ',') 'Claude Code,Antigravity CLI,goose CLI' '-NoUpgrade keeps present native commands'
        Assert-Equal $script:WingetCalls.Count 0 'no WinGet copies remain to retire'

        # ARM64 (native, even from an emulated x64 host): goose has no
        # upstream build, so it is skipped rather than failed.
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
        Remove-Item -LiteralPath (Get-NativeCliPath -Tool ($NativeCliTools | Where-Object { $_.Name -eq 'goose CLI' })) -Force
        $script:InstallerRuns = @()
        $native = Invoke-NativeCliSet -InstalledIds @()
        Assert-Equal ($script:InstallerRuns -join ',') 'Claude Code,Codex CLI,Antigravity CLI' 'ARM64 never runs the goose installer'
        Assert-Equal ($native.Skipped -join ',') 'goose CLI' 'ARM64 reports goose as skipped'
        Assert-Equal $native.Failed.Count 0 'an unsupported architecture is not a failure'
        Assert-Equal (Test-NativeCliSupported -Tool @{ Name = 'any' }) $true 'tools without an architecture list run everywhere'

        # Goose Desktop: release selection binds one stable asset to its digest.
        $sha = 'A' * 64
        $releaseFixture = {
            param([string]$Tag = 'v1.55.0', [string]$Digest = "sha256:$sha", [string]$Name = 'Goose-win32-x64.zip', [bool]$Prerelease = $false)
            [pscustomobject]@{
                tag_name = $Tag; prerelease = $Prerelease; draft = $false
                assets = @(
                    [pscustomobject]@{ name = 'Goose-win32-x64-cuda.zip'; browser_download_url = "https://github.com/aaif-goose/goose/releases/download/$Tag/Goose-win32-x64-cuda.zip"; digest = "sha256:$('b' * 64)" }
                    [pscustomobject]@{ name = $Name; browser_download_url = "https://github.com/aaif-goose/goose/releases/download/$Tag/$Name"; digest = $Digest }
                )
            }
        }
        $selected = Select-GooseDesktopAsset -Release (& $releaseFixture)
        Assert-Equal $selected.Version '1.55.0' 'Goose Desktop version comes from the release tag'
        Assert-Equal $selected.Url 'https://github.com/aaif-goose/goose/releases/download/v1.55.0/Goose-win32-x64.zip' 'Goose Desktop selects the standard x64 zip'
        Assert-Equal $selected.Sha256 ('a' * 64) 'Goose Desktop digest is normalized'
        foreach ($case in @(
                @{ Release = (& $releaseFixture -Digest ''); Pattern = '*no published SHA-256*' }
                @{ Release = (& $releaseFixture -Digest "sha512:$sha"); Pattern = '*no published SHA-256*' }
                @{ Release = (& $releaseFixture -Name 'Goose-win32-x64-setup.exe'); Pattern = '*lacks exactly one*' }
                @{ Release = (& $releaseFixture -Tag 'stable'); Pattern = '*unsupported tag*' }
                @{ Release = (& $releaseFixture -Prerelease $true); Pattern = '*not a stable release*' })) {
            $rejected = $false
            try { Select-GooseDesktopAsset -Release $case.Release | Out-Null }
            catch { $rejected = $_.Exception.Message -like $case.Pattern }
            Assert-Equal $rejected $true "Goose Desktop release rejected ($($case.Pattern))"
        }
        $offOrigin = & $releaseFixture
        $offOrigin.assets[1].browser_download_url = 'https://example.invalid/Goose-win32-x64.zip'
        $rejected = $false
        try { Select-GooseDesktopAsset -Release $offOrigin | Out-Null }
        catch { $rejected = $_.Exception.Message -like '*outside the expected*' }
        Assert-Equal $rejected $true 'Goose Desktop asset URL must be the release download path'

        # The app root is the Goose.exe beside resources/, not the bundled
        # CLI at resources\bin\goose.exe.
        $zipTree = Join-Path $nativeRoot 'goose-zip'
        New-Item -ItemType Directory -Force -Path (Join-Path $zipTree 'dist-windows\resources\bin') | Out-Null
        Set-Content -LiteralPath (Join-Path $zipTree 'dist-windows\Goose.exe') -Value 'app'
        Set-Content -LiteralPath (Join-Path $zipTree 'dist-windows\resources\bin\goose.exe') -Value 'cli'
        Assert-Equal (Find-GooseDesktopAppDirectory -Path $zipTree) (Join-Path $zipTree 'dist-windows') 'Goose Desktop app root ignores the bundled goose.exe CLI'
        Remove-Item -LiteralPath (Join-Path $zipTree 'dist-windows\Goose.exe') -Force
        $rejected = $false
        try { Find-GooseDesktopAppDirectory -Path $zipTree | Out-Null }
        catch { $rejected = $_.Exception.Message -like '*exactly one Goose.exe app directory*' }
        Assert-Equal $rejected $true 'an archive without the Goose Desktop app is rejected'

        # Goose Desktop step: install, convergence, update, -NoUpgrade, ARM64 skip.
        $script:DesktopInstalls = @()
        $script:DesktopRelease = [pscustomobject]@{ Version = '1.55.0'; Name = 'Goose-win32-x64.zip'; Url = 'u'; Sha256 = 'a' * 64 }
        function Get-GooseDesktopRelease { return $script:DesktopRelease }
        function Install-GooseDesktop {
            param($Release)
            $script:DesktopInstalls += $Release.Version
            $root = Get-GooseDesktopRoot
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'Goose.exe') -Value 'exe'
            Set-Content -LiteralPath (Join-Path $root $GooseDesktopMarkerName) -Value @("version=$($Release.Version)", "sha256=$($Release.Sha256)")
        }
        $env:PROCESSOR_ARCHITEW6432 = $null
        Assert-Equal (Invoke-GooseDesktopStep) 'installed' 'missing Goose Desktop is installed'
        Assert-Equal (Get-GooseDesktopInstall).Version '1.55.0' 'Goose Desktop marker records the release'
        Assert-Equal (Invoke-GooseDesktopStep) 'current' 'matching Goose Desktop release is current'
        $script:DesktopRelease = [pscustomobject]@{ Version = '1.56.0'; Name = 'Goose-win32-x64.zip'; Url = 'u'; Sha256 = 'c' * 64 }
        Assert-Equal (Invoke-GooseDesktopStep -NoUpgrade) 'current' '-NoUpgrade keeps an installed Goose Desktop'
        Assert-Equal (Invoke-GooseDesktopStep) 'updated' 'newer Goose Desktop release replaces the zip build'
        Assert-Equal ($script:DesktopInstalls -join ',') '1.55.0,1.56.0' 'Goose Desktop installs only when missing or outdated'
        $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
        Assert-Equal (Invoke-GooseDesktopStep) 'skipped' 'ARM64 skips Goose Desktop'
        $env:PROCESSOR_ARCHITEW6432 = $null
        function Get-GooseDesktopRelease { throw 'rate limited' }
        Assert-Equal (Invoke-GooseDesktopStep 3>$null) 'failed' 'a failed Goose Desktop release lookup is reported'
    }
    finally {
        $env:USERPROFILE = $savedRoots.USERPROFILE
        $env:LOCALAPPDATA = $savedRoots.LOCALAPPDATA
        $env:PROCESSOR_ARCHITECTURE = $savedRoots.PROCESSOR_ARCHITECTURE
        $env:PROCESSOR_ARCHITEW6432 = $savedRoots.PROCESSOR_ARCHITEW6432
        Remove-Item -LiteralPath $nativeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -Path Function:\global:winget -ErrorAction SilentlyContinue
}

Write-Output 'ALL WINGET MIGRATION ASSERTIONS PASSED'

# The OpenCode native-purge tests ride along with this CI-listed test.
& (Join-Path $PSScriptRoot 'Test-OpenCodePurge.ps1')
