param(
    [string]$ScriptPath = (Join-Path (Join-Path $PSScriptRoot '..') 'setup-win11-workstation.ps1')
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) {
    throw "Script has parser errors: $($parseErrors -join '; ')"
}
$tokens.Count | Out-Null

foreach ($assignmentName in @('WingetPackages', 'WingetFullPackages', 'WingetLegacyPackages', 'WingetPresenceOnlyPackages',
                              'RustComponents', 'BalunWingetId', 'BalunRepo', 'BalunDisplayName', 'BalunInstallerArgs', 'WingetOkCodes', 'WingetRebootCodes', 'WingetDeferredCodes', 'WingetRemoveOkCodes')) {
    $assignmentAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq $assignmentName
    }, $false)
    if (-not $assignmentAst) { throw "$assignmentName declaration not found" }
    . ([scriptblock]::Create($assignmentAst.Extent.Text))
}
foreach ($functionName in @('Write-Note', 'Invoke-WingetPackageSet', 'Get-RustupStableComponent',
                            'Test-RustupDefaultToolchain', 'Initialize-RustupToolchain',
                            'Get-WindowsArchitectureName', 'Get-BalunRelease', 'Invoke-BalunStep')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if (-not $functionAst) { throw "$functionName function not found" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

# --- Profile contents --------------------------------------------------------
$core = @($WingetPackages)
$full = @($WingetPackages) + @($WingetFullPackages)
foreach ($id in @('Valve.Steam', 'GOG.Galaxy', 'SuperTuxKart.SuperTuxKart', 'Plex.Plex')) {
    Assert-True ($core -notcontains $id) "$id must be full-only"
    Assert-True ($full -contains $id) "$id must be in full"
}
foreach ($id in @('Rustlang.Rustup', 'Google.Chrome', 'Mozilla.Firefox', 'LLVM.LLVM', 'GoLang.Go',
                  'Google.AndroidStudio', 'Microsoft.VisualStudio.Community', 'Microsoft.PowerShell', 'Git.Git')) {
    Assert-True ($core -contains $id) "$id must be in core"
}
Assert-True (@($full | Select-Object -Unique).Count -eq $full.Count) 'core and full package IDs do not overlap'
Assert-True (@($full | Where-Object { $_ -like 'Rustlang.Rust.*' }).Count -eq 0) 'no standalone Rust MSI in any profile'
foreach ($id in @('Rustlang.Rust.MSVC', 'Rustlang.Rust.GNU')) {
    Assert-True ($WingetLegacyPackages -contains $id) "$id is removed in favor of rustup"
}
Assert-True ((Get-Content -Raw -LiteralPath $ScriptPath) -notmatch '(?i)r8152') 'no r8152 handling on Windows'
Assert-True ((Get-Content -Raw -LiteralPath $ScriptPath) -notmatch '(?m)^#Requires\s+-RunAsAdministrator') 'elevation is a runtime check so previews run unelevated'
$scriptText = Get-Content -Raw -LiteralPath $ScriptPath
Assert-True ($core -contains 'jm2.Tributary') 'Tributary is in core'
Assert-True ($scriptText -match '(?m)^\$balunResult = Invoke-BalunStep ') 'Balun step runs in every profile (core)'
Assert-True ($scriptText.IndexOf('Invoke-BalunStep -InstalledIds') -lt $scriptText.IndexOf('#--- 4. Self-updating native CLIs')) 'Balun step is part of the package phase'
Assert-True (($BalunInstallerArgs -join ' ') -eq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-') 'Balun uses Inno Setup silent switches'
Write-Output 'PROFILE CONTENTS PASSED'

# --- Parameter validation ----------------------------------------------------
$threw = $false
try { & $ScriptPath -Profile other -DryRun 6>$null } catch { $threw = $true }
Assert-True $threw 'invalid -Profile is rejected'
$threw = $false
try { & $ScriptPath -Check -DryRun 6>$null } catch { $threw = $_.Exception.Message -match 'one preview mode' }
Assert-True $threw '-Check and -DryRun are mutually exclusive'
Write-Output 'PARAMETER VALIDATION PASSED'

# --- Dry run is offline and read-only ----------------------------------------
$script:Calls = @()
$mockNames = @('winget', 'rustup', 'Get-WindowsCapability', 'Add-WindowsCapability', 'Get-WindowsOptionalFeature',
               'Enable-WindowsOptionalFeature', 'Get-Service', 'Set-Service', 'Start-Service', 'Get-NetFirewallRule',
               'New-NetFirewallRule', 'New-ItemProperty', 'Set-ItemProperty', 'Get-ItemProperty', 'Invoke-WebRequest')
foreach ($name in $mockNames) {
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("`$script:Calls += '$name'; `$global:LASTEXITCODE = 0"))
}
try {
    foreach ($profileName in @('core', 'full')) {
        $script:Calls = @()
        $global:LASTEXITCODE = 99
        $output = @(& $ScriptPath -Profile $profileName -DryRun -HyperV 6>&1 | ForEach-Object { [string]$_ })
        Assert-True ($LASTEXITCODE -eq 0) "$profileName dry run exits 0 (got $LASTEXITCODE)"
        Assert-True ($script:Calls.Count -eq 0) "$profileName dry run made no system calls (got $($script:Calls -join ', '))"
        $text = $output -join "`n"
        Assert-True ($text -match "Profile: $profileName; mode: dry-run") "$profileName dry run announces profile and mode"
        Assert-True ($text -match 'Rustlang\.Rustup') "$profileName dry run lists rustup"
        Assert-True ($text -match 'Balun: WinGet jm2\.Balun when it resolves') "$profileName dry run lists the Balun plan"
        Assert-True ($text -match 'Hyper-V: enable') "$profileName dry run lists the Hyper-V step"
        Assert-True (($text -match 'Valve\.Steam') -eq ($profileName -eq 'full')) "Steam listed only for full ($profileName)"
    }
}
finally {
    foreach ($name in $mockNames) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
}
Write-Output 'DRY RUN PASSED'

# --- -NoUpgrade installs missing packages only -------------------------------
$script:WingetCalls = @()
function global:winget { $script:WingetCalls += ($args -join '|'); $global:LASTEXITCODE = 0 }
try {
    $result = Invoke-WingetPackageSet -InstalledIds @('Git.Git') -DesiredIds @('Git.Git', 'GitHub.cli') -NoUpgrade 6>$null
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like 'upgrade|*' }).Count -eq 0) '-NoUpgrade skips upgrade checks'
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like 'install|--id|GitHub.cli|*' }).Count -eq 1) '-NoUpgrade still installs missing packages'
    Assert-True ($result.Present -contains 'Git.Git') 'installed package is reported present'
    $script:WingetCalls = @()
    Invoke-WingetPackageSet -InstalledIds @('Git.Git') -DesiredIds @('Git.Git') 6>$null | Out-Null
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like 'upgrade|--id|Git.Git|*' }).Count -eq 1) 'default mode checks installed packages for upgrades'
}
finally {
    Remove-Item -Path function:global:winget -ErrorAction SilentlyContinue
}
Write-Output 'NO-UPGRADE PASSED'

# --- rustup initialization ---------------------------------------------------
$script:RustupCalls = @()
$script:RustupDefault = $false
$script:RustupComponents = @('cargo-x86_64-pc-windows-msvc', 'rustc-x86_64-pc-windows-msvc')
function global:rustup {
    $call = $args -join ' '
    $script:RustupCalls += $call
    $global:LASTEXITCODE = 0
    if ($call -eq 'default') {
        if ($script:RustupDefault) { return 'stable-x86_64-pc-windows-msvc (default)' }
        $global:LASTEXITCODE = 1; return
    }
    if ($call -eq 'default stable') { $script:RustupDefault = $true; return }
    if ($call -like 'component list*') { return $script:RustupComponents }
    if ($call -like 'component add*') {
        $script:RustupComponents += @($args | Select-Object -Skip 4 | ForEach-Object { "$_-x86_64-pc-windows-msvc" })
    }
}
function Get-RustupPath { 'rustup' }
try {
    $status = Initialize-RustupToolchain -NoUpgrade 6>$null
    Assert-True ($status -eq 'changed') "fresh rustup is initialized (got $status)"
    Assert-True ($script:RustupCalls -contains 'default stable') 'stable becomes the default when none is set'
    Assert-True ($script:RustupCalls -contains 'component add --toolchain stable rustfmt clippy rust-analyzer') 'editor components are added'
    $script:RustupCalls = @()
    $status = Initialize-RustupToolchain -NoUpgrade 6>$null
    Assert-True ($status -eq 'current') "converged rustup is current (got $status)"
    Assert-True (@($script:RustupCalls | Where-Object { $_ -match '^(default stable|update|component add)' }).Count -eq 0) 'converged -NoUpgrade rustup makes no changes'
    $script:RustupCalls = @()
    Initialize-RustupToolchain 6>$null | Out-Null
    Assert-True ($script:RustupCalls -contains 'update stable --no-self-update') 'default mode updates the stable toolchain'
    Assert-True ($script:RustupCalls -notcontains 'default stable') 'an existing default toolchain is preserved'
}
finally {
    Remove-Item -Path function:global:rustup -ErrorAction SilentlyContinue
}
Write-Output 'RUSTUP PASSED'
# --- Balun: WinGet first, verified release fallback --------------------------
$script:BalunCalls = @()
$script:BalunWinget = $false
$script:BalunExisting = $null
$script:BalunWingetExit = 0
function global:winget { $script:BalunCalls += ($args -join '|'); $global:LASTEXITCODE = $script:BalunWingetExit }
function Test-WingetPackageAvailable { param($Id) $script:BalunCalls += "show|$Id"; return $script:BalunWinget }
function Get-BalunInstall { return $script:BalunExisting }
function Get-BalunRelease { $script:BalunCalls += 'release'; [pscustomobject]@{ Version = '0.2.0'; Name = 'balun-windows-x86_64-setup.exe'; Url = 'u'; Sha256 = 'a' * 64 } }
function Install-BalunFromRelease { param($Release) $script:BalunCalls += "release-install|$($Release.Version)" }
function Invoke-BalunCase {
    param([bool]$Winget, $Existing, [string[]]$InstalledIds, [bool]$NoUpgrade)
    $script:BalunCalls = @(); $script:BalunWinget = $Winget; $script:BalunExisting = $Existing
    return (Invoke-BalunStep -InstalledIds $InstalledIds -NoUpgrade:$NoUpgrade 6>$null 3>$null)
}
try {
    $old = [pscustomobject]@{ Version = '0.1.1'; Key = '{3B7A0CD1-33F6-5D60-9973-2B7A1B53E02A}_is1' }
    $status = Invoke-BalunCase $true $null @() $false
    Assert-True ($status -eq 'installed') "WinGet installs Balun when the ID resolves (got $status)"
    Assert-True (@($script:BalunCalls | Where-Object { $_ -like 'install|--id|jm2.Balun|*' }).Count -eq 1) 'WinGet install of jm2.Balun'
    Assert-True ($script:BalunCalls -notcontains 'release') 'no release fallback when WinGet resolves'

    $status = Invoke-BalunCase $true $old @() $false
    Assert-True ($status -eq 'updated') "WinGet adopts a release-installed Balun (got $status)"
    Assert-True (@($script:BalunCalls | Where-Object { $_ -like 'install|*' -and $_ -notmatch 'no-upgrade' }).Count -eq 1) 'adoption install may replace the release copy in place'
    Assert-True (@($script:BalunCalls | Where-Object { $_ -like 'release*' }).Count -eq 0) 'adoption never runs the release installer too'

    $status = Invoke-BalunCase $true $old @('jm2.Balun') $false
    Assert-True (@($script:BalunCalls | Where-Object { $_ -like 'upgrade|--id|jm2.Balun|*' }).Count -eq 1) 'WinGet-owned Balun gets an upgrade check'

    $status = Invoke-BalunCase $true $old @('jm2.Balun') $true
    Assert-True ($status -eq 'current' -and @($script:BalunCalls | Where-Object { $_ -match '^(install|upgrade)\|' }).Count -eq 0) '-NoUpgrade leaves WinGet-owned Balun alone'

    $status = Invoke-BalunCase $false $null @() $false
    Assert-True ($status -eq 'installed' -and $script:BalunCalls -contains 'release-install|0.2.0') 'release fallback installs when WinGet lacks the ID'

    $status = Invoke-BalunCase $false $old @() $true
    Assert-True ($status -eq 'current' -and $script:BalunCalls -notcontains 'release') '-NoUpgrade skips the release lookup for an installed Balun'

    $status = Invoke-BalunCase $false ([pscustomobject]@{ Version = '0.2.0'; Key = 'k' }) @() $false
    Assert-True ($status -eq 'current' -and $script:BalunCalls -notcontains 'release-install|0.2.0') 'matching release version is current'

    $status = Invoke-BalunCase $false $old @() $false
    Assert-True ($status -eq 'updated' -and $script:BalunCalls -contains 'release-install|0.2.0') 'older release install is updated from the release'

    $script:BalunWingetExit = 1
    $status = Invoke-BalunCase $true $null @() $false
    Assert-True ($status -eq 'failed') 'WinGet failure is reported'
    $script:BalunWingetExit = 0
}
finally {
    Remove-Item -Path function:global:winget -ErrorAction SilentlyContinue
}

# Release resolution cross-checks SHA256SUMS.txt against the GitHub digest.
${function:Get-BalunRelease} = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BalunRelease'
}, $true).Body.GetScriptBlock()
$sum = 'c' * 64
$script:ReleaseDigest = "sha256:$sum"
$script:SumsBody = "$('d' * 64)  balun-windows-aarch64-setup.exe`n$sum  balun-windows-x86_64-setup.exe`n"
# Mock the web cmdlets in this scope only (dynamically, so the analyzer does
# not mistake them for permanent overrides of the built-ins).
Set-Item -Path function:Invoke-RestMethod -Value {
    [pscustomobject]@{
        tag_name = 'v0.2.0'; prerelease = $false; draft = $false
        assets = @(
            [pscustomobject]@{ name = 'balun-windows-x86_64-setup.exe'; browser_download_url = 'exe'; digest = $script:ReleaseDigest }
            [pscustomobject]@{ name = 'SHA256SUMS.txt'; browser_download_url = 'sums'; digest = '' }
        )
    }
}
Set-Item -Path function:Invoke-WebRequest -Value {
    $outFile = $args[[Array]::IndexOf([object[]]$args, '-OutFile') + 1]
    Set-Content -LiteralPath $outFile -Value $script:SumsBody -NoNewline
}
$savedArch = $env:PROCESSOR_ARCHITECTURE; $savedWow = $env:PROCESSOR_ARCHITEW6432
try {
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'; $env:PROCESSOR_ARCHITEW6432 = $null
    $release = Get-BalunRelease
    Assert-True ($release.Name -eq 'balun-windows-x86_64-setup.exe' -and $release.Sha256 -eq $sum -and $release.Version -eq '0.2.0') 'release asset and checksum resolved for x86_64'
    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    $threw = $false
    try { Get-BalunRelease | Out-Null } catch { $threw = $_.Exception.Message -match 'lacks exactly one' }
    Assert-True $threw 'aarch64 host selects the aarch64 asset (absent in this fixture)'
    $env:PROCESSOR_ARCHITEW6432 = $null
    $script:ReleaseDigest = "sha256:$('e' * 64)"
    $threw = $false
    try { Get-BalunRelease | Out-Null } catch { $threw = $_.Exception.Message -match 'disagrees' }
    Assert-True $threw 'digest/SHA256SUMS disagreement is rejected'
    $script:ReleaseDigest = ''
    Assert-True ((Get-BalunRelease).Sha256 -eq $sum) 'missing GitHub digest falls back to SHA256SUMS.txt alone'
}
finally {
    $env:PROCESSOR_ARCHITECTURE = $savedArch; $env:PROCESSOR_ARCHITEW6432 = $savedWow
    Remove-Item -Path function:Invoke-RestMethod, function:Invoke-WebRequest -ErrorAction SilentlyContinue
}
Write-Output 'BALUN PASSED'
Write-Output 'ALL WIN11 PROFILE ASSERTIONS PASSED'
