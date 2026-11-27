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

foreach ($assignmentName in @('WingetPackages', 'WingetFullPackages', 'WingetFullStorePackages', 'WingetStorePackageNames', 'WingetLegacyPackages', 'WingetPresenceOnlyPackages',
                              'RustComponents', 'ReleaseApps', 'ReleaseAppInstallerArgs', 'PowerShellRepo', 'PowerShellMetadataUrl', 'PowerShellMsiProperties', 'PowerShellMsiLog', 'MsiOkCodes', 'MsiRebootCodes', 'MsiBusyCode', 'MsiBusyAttempts', 'MsiBusyRetrySeconds', 'WingetOkCodes', 'WingetRebootCodes', 'WingetDeferredCodes', 'WingetRemoveOkCodes', 'WingetUserScopeElevatedCode', 'WingetSelfUpdatingCode', 'WingetLaunchAttempts', 'WingetLaunchRetrySeconds', 'WingetInstallTechMismatchCode', 'WingetUninstallWaitSeconds', 'WingetUninstallPollSeconds', 'NativeCliTools', 'WingetPackageArgs', 'GooGetGitHubRepo', 'GooGetPatchedRepo', 'GooGetPatchedCommit', 'GooGetPatchedPulls', 'GooGetRepoName', 'GooGetRepoUrl', 'GooGetRetiredRepos', 'GooGetAclTrustedSids', 'GooGetPackages', 'GooGetFullPackages', 'GooGetProbeTimeoutSeconds',
                              'GamesExcludePattern', 'GamesReservePercent', 'GamesSizeFactor', 'GamesBootstrapWingetPackages', 'VentoyRepo', 'VentoyMarkerName')) {
    $assignmentAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq $assignmentName
    }, $false)
    if (-not $assignmentAst) { throw "$assignmentName declaration not found" }
    . ([scriptblock]::Create($assignmentAst.Extent.Text))
}
foreach ($functionName in @('Write-Note', 'Invoke-Winget', 'Invoke-WingetUninstall', 'Get-WingetPackageArgument', 'Get-WingetArpEntry', 'Test-NsisExecutable', 'Remove-WingetPackageForReinstall', 'Wait-WingetPackageRemoved', 'Split-UninstallCommand', 'Invoke-UninstallCommand', 'Invoke-WingetPackageSet', 'Get-RustupStableComponent',
                            'Test-RustupDefaultToolchain', 'Initialize-RustupToolchain',
                            'Get-NativeProcessorArchitecture', 'Get-WindowsArchitectureName', 'Get-VerifiedReleaseAsset', 'Get-ReleaseAppRelease', 'Invoke-ReleaseAppStep', 'Get-VentoyRoot', 'Get-VentoyInstall', 'Restore-InterruptedTreeSwap', 'Switch-StagedTree', 'Get-VentoyShortcutTarget', 'Select-VentoyAsset', 'Get-VentoyRelease', 'Find-VentoyAppDirectory', 'Get-VentoyNativeExeName', 'Install-Ventoy', 'Invoke-VentoyStep', 'Get-PowerShellLtsVersion', 'Get-PowerShellLtsRelease', 'Invoke-Msiexec',
                            'Invoke-PowerShellMsiSwitch', 'Select-GooGetSource', 'Test-GooGetPatchPending', 'Get-GooGetConfText', 'Get-GooGetRepoFileText', 'Get-GooGetRetiredRepoFile', 'Read-TextOrEmpty', 'Test-GooGetWriteRight',
                            'Get-GooGetInstalledName', 'Get-GooGetInstalledPackage', 'Invoke-GooGetPackageSet',
                            'Get-GameSourceRank', 'Get-GameKey', 'Select-GamePackage', 'Get-GooGetArchPreference', 'Compare-GooGetVersion', 'Select-GooGetIndexEntry')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if (-not $functionAst) { throw "$functionName function not found" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

# The scheduled-task retry is exercised in Test-WingetAntigravity; here a
# user-scope refusal simply has no unelevated retry available.
# No param block: the named arguments the script passes land in $args.
function Invoke-WingetUninstallUnelevated { return $null }
function Invoke-WingetUpgradeUnelevated { return $null }

# --- Profile contents --------------------------------------------------------
$core = @($WingetPackages)
$full = @($WingetPackages) + @($WingetFullPackages)
foreach ($id in @('Valve.Steam', 'GOG.Galaxy', 'SuperTuxKart.SuperTuxKart', 'Plex.Plex')) {
    Assert-True ($core -notcontains $id) "$id must be full-only"
    Assert-True ($full -contains $id) "$id must be in full"
}
foreach ($id in @('Rustlang.Rustup', 'Google.Chrome', 'Mozilla.Firefox', 'LLVM.LLVM', 'GoLang.Go',
                  'Google.AndroidStudio', 'Microsoft.VisualStudio.Community', 'Git.Git')) {
    Assert-True ($core -contains $id) "$id must be in core"
}
Assert-True (@($full | Select-Object -Unique).Count -eq $full.Count) 'core and full package IDs do not overlap'
Assert-True ($full -notcontains 'Microsoft.PowerShell') 'PowerShell 7 is the GitHub LTS MSI, not the WinGet stable package'
Assert-True ($full -notcontains 'Apple.iTunes') 'iTunes is replaced by the Store Apple Music and Apple TV apps'
foreach ($id in @('9PFHDD62MXS1', '9NM4T8B9JQZ1')) {
    Assert-True ($WingetFullStorePackages -contains $id) "Store app $id must be in full"
}
foreach ($id in $WingetFullStorePackages) {
    Assert-True ([bool]$WingetStorePackageNames[$id]) "Store app $id has a display name"
}
Assert-True (@($full | Where-Object { $_ -like 'Rustlang.Rust.*' }).Count -eq 0) 'no standalone Rust MSI in any profile'
foreach ($id in @('Rustlang.Rust.MSVC', 'Rustlang.Rust.GNU')) {
    Assert-True ($WingetLegacyPackages -contains $id) "$id is removed in favor of rustup"
}
Assert-True ((Get-Content -Raw -LiteralPath $ScriptPath) -notmatch '(?i)r8152') 'no r8152 handling on Windows'
Assert-True ((Get-Content -Raw -LiteralPath $ScriptPath) -notmatch '(?m)^#Requires\s+-RunAsAdministrator') 'elevation is a runtime check so previews run unelevated'
$scriptText = Get-Content -Raw -LiteralPath $ScriptPath
Assert-True ($core -contains 'jm2.Tributary') 'Tributary is in core'
Assert-True ($full -notcontains 'Ventoy.Ventoy') 'Ventoy is the GitHub release, not the broken WinGet portable package'
Assert-True ($WingetLegacyPackages -contains 'Ventoy.Ventoy') 'a WinGet Ventoy is removed in favor of the release'
Assert-True ($scriptText -match '(?m)^\$ventoyResult = Invoke-VentoyStep ') 'Ventoy step runs in core and full'
Assert-True ($scriptText.IndexOf('Invoke-VentoyStep -NoUpgrade') -lt $scriptText.IndexOf('#--- 4. Self-updating native CLIs')) 'Ventoy step is part of the package phase'
Assert-True ($scriptText.Contains("-or `$ventoyResult -eq 'failed'")) 'a failed Ventoy step fails the run'
Assert-True ($scriptText -match '(?m)^    \$releaseAppResults\[\$app\.Name\] = Invoke-ReleaseAppStep ') 'release-app step runs in every profile (core)'
Assert-True ($scriptText.IndexOf('Invoke-ReleaseAppStep -App $app -InstalledIds') -lt $scriptText.IndexOf('#--- 4. Self-updating native CLIs')) 'release-app step is part of the package phase'
Assert-True ($scriptText.Contains("@(`$releaseAppResults.Values) -contains 'failed'")) 'a failed release app fails the run'
Assert-True ((@($ReleaseApps | ForEach-Object Name) -join ' ') -eq 'Balun Transom') 'Balun and Transom are the release apps'
foreach ($app in $ReleaseApps) {
    Assert-True ($app.WingetId -eq "jm2.$($app.Name)" -and $app.Repo -eq "jm2/$($app.Name.ToLowerInvariant())" -and $app.DisplayName -eq $app.Name) "$($app.Name) release-app entry"
    Assert-True (($app.AssetFormat -f 'x86_64') -eq "$($app.Name.ToLowerInvariant())-windows-x86_64-setup.exe") "$($app.Name) asset name"
}
Assert-True (($ReleaseAppInstallerArgs -join ' ') -eq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-') 'release apps use Inno Setup silent switches'
foreach ($tool in @($NativeCliTools | Where-Object { $_.RelativePath -like '.local\bin\*' })) {
    # goose also adds .local\bin but is x64-only, so each tool there adds it itself.
    Assert-True ([bool]$tool.AddToUserPath) "$($tool.Name) puts %USERPROFILE%\.local\bin on the user PATH"
}
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
        Assert-True ($text -match 'Balun: WinGet jm2\.Balun when it resolves; otherwise the latest stable jm2/balun release') "$profileName dry run lists the Balun plan"
        Assert-True ($text -match 'Transom: WinGet jm2\.Transom when it resolves; otherwise the latest stable jm2/transom release') "$profileName dry run lists the Transom plan"
        Assert-True ($text -match 'transom-windows-<x86_64\|aarch64>-setup\.exe') "$profileName dry run names the Transom installer"
        Assert-True ($text -match 'Hyper-V: enable') "$profileName dry run lists the Hyper-V step"
        Assert-True ($text -match 'Ventoy: latest stable ventoy/Ventoy release ventoy-<version>-windows\.zip') "$profileName dry run lists the Ventoy release plan"
        Assert-True ($text -match 'a copy this script did not') "$profileName dry run says an unrecorded Ventoy is replaced"
        Assert-True ($text -match 'goose CLI: https://raw\.githubusercontent\.com/aaif-goose/goose/main/download_cli\.ps1 .*AMD64 only') "$profileName dry run lists the x64-only goose CLI"
        Assert-True ($text -match 'Goose Desktop \(AMD64 only; skipped elsewhere\)') "$profileName dry run lists the x64-only Goose Desktop"
        Assert-True ($text -match 'charmbracelet\.crush') "$profileName dry run lists Crush"
        Assert-True ($text -match 'GooGet: go build of jm2/googet@645ecb0cbbef \(git checkout\) until google/googet PRs #227, #228 merge') "$profileName dry run lists the patched GooGet build"
        Assert-True ($text -match 'then go install from the head of google/googet') "$profileName dry run lists the upstream GooGet build"
        Assert-True ($text -match 'repo game-packages -> http://192\.168\.1\.11:8080/goo/game-packages') "$profileName dry run lists the game-packages GooGet repo"
        Assert-True ($text -match 'removes repos\\linux-packages\.repo while it still points at http://192\.168\.1\.11:8080/goo/linux-packages') "$profileName dry run lists the retired repo removal"
        Assert-True ($text.IndexOf('SST.opencode') -gt $text.IndexOf('Legacy packages removed') -and $text -match 'SST\.OpenCodeDesktop') "$profileName dry run purges, not installs, OpenCode"
        Assert-True (($text -match 'Valve\.Steam') -eq ($profileName -eq 'full')) "Steam listed only for full ($profileName)"
        $gooPlan = @($output | Select-Object -Skip ([Array]::FindIndex([string[]]$output, [Predicate[string]]{ param($l) $l -match 'game-packages GooGet packages' }) + 1) |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[a-z0-9-]+$' })
        $expectedGoo = if ($profileName -eq 'full') { 'crossdock,carryout,bugdom,bugdom2,cro-mag-rally-net,mightymike,nanosaur,nanosaur2,ottomatic' } else { 'crossdock,carryout' }
        Assert-True (($gooPlan -join ',') -eq $expectedGoo) "$profileName dry run lists the game-packages GooGet set (got $($gooPlan -join ','))"
    }
    $script:Calls = @()
    $global:LASTEXITCODE = 99
    $output = @(& $ScriptPath -Profile games -DryRun 6>&1 | ForEach-Object { [string]$_ })
    Assert-True ($LASTEXITCODE -eq 0) "games dry run exits 0 (got $LASTEXITCODE)"
    Assert-True ($script:Calls.Count -eq 0) "games dry run made no system calls (got $($script:Calls -join ', '))"
    $text = $output -join "`n"
    Assert-True ($text -match 'Profile: games; mode: dry-run') 'games dry run announces profile and mode'
    Assert-True ($text -match 'Standalone: nothing from the core or full profiles') 'games dry run is standalone'
    Assert-True ($text -match 'GoLang\.Go, Git\.Git') 'games dry run installs what the GooGet build needs'
    Assert-True ($text -match 'repo game-packages -> http://192\.168\.1\.11:8080/goo/game-packages') 'games dry run lists the GooGet repo'
    Assert-True ($text -match 'GOG, Steam, other sources' -and $text -match '20% of the Program Files drive') 'games dry run states source order and reserve'
    foreach ($id in @('Rustlang.Rustup', 'Valve.Steam', 'Google.Chrome', 'Hyper-V', 'OpenSSH')) {
        Assert-True ($text.IndexOf($id) -lt 0) "games dry run leaves out $id"
    }
    $script:Calls = @()
    $global:LASTEXITCODE = 99
    $output = @(& $ScriptPath -Profile games-repo -DryRun 6>&1 | ForEach-Object { [string]$_ })
    Assert-True ($LASTEXITCODE -eq 0) "games-repo dry run exits 0 (got $LASTEXITCODE)"
    Assert-True ($script:Calls.Count -eq 0) "games-repo dry run made no system calls (got $($script:Calls -join ', '))"
    $text = $output -join "`n"
    Assert-True ($text -match 'Profile: games-repo; mode: dry-run') 'games-repo dry run announces profile and mode'
    Assert-True ($text -match 'Standalone: nothing from the core or full profiles') 'games-repo dry run is standalone'
    Assert-True ($text -match 'GoLang\.Go, Git\.Git') 'games-repo dry run installs what the GooGet build needs'
    Assert-True ($text -match 'repo game-packages -> http://192\.168\.1\.11:8080/goo/game-packages') 'games-repo dry run lists the GooGet repo'
    Assert-True ($text -match 'No games') 'games-repo dry run installs no games'
    foreach ($id in @('GOG, Steam', 'Program Files drive', 'Rustlang.Rustup', 'Valve.Steam', 'Google.Chrome', 'Hyper-V', 'OpenSSH')) {
        Assert-True ($text.IndexOf($id) -lt 0) "games-repo dry run leaves out $id"
    }
}
finally {
    foreach ($name in $mockNames) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
}
Write-Output 'DRY RUN PASSED'

# --- games profile: selection --------------------------------------------------
function Get-TestGame {
    param([string]$Name, [double]$Size = 1GB, [string[]]$Provides = @(), [string[]]$Conflicts = @(), [string[]]$Depends = @())
    [pscustomobject]@{ Name = $Name; Size = $Size; Provides = $Provides; Conflicts = $Conflicts; Depends = $Depends }
}
Assert-True ((Get-GameSourceRank -Name 'quake3-data-gog') -lt (Get-GameSourceRank -Name 'quake3-data-steam')) 'GOG ranks before Steam'
Assert-True ((Get-GameSourceRank -Name 'wreckfest-gog-dlc1') -eq 0) 'a GOG DLC ranks as GOG'
Assert-True ((Get-GameSourceRank -Name 'ut2004-data-steam') -lt (Get-GameSourceRank -Name 'ut2004-data-archiveorg')) 'Steam ranks before archive.org'
Assert-True ((Get-GameKey -Name 'wreckfest-steam') -eq 'wreckfest' -and (Get-GameKey -Name 'etlegacy-bin') -eq 'etlegacy-bin') 'game key strips only a trailing source'
$catalog = @(
    (Get-TestGame 'crossdock' 10MB),
    (Get-TestGame 'ut2004-data-archiveorg' 5GB @('ut2004-data') @('ut2004-data-gog', 'ut2004-data-steam')),
    (Get-TestGame 'ut2004-data-gog' 5GB @('ut2004-data') @('ut2004-data-archiveorg', 'ut2004-data-steam')),
    (Get-TestGame 'ut2004-data-steam' 5GB @('ut2004-data') @('ut2004-data-archiveorg', 'ut2004-data-gog')),
    (Get-TestGame 'ut2004-bin' 150MB @() @() @('ut2004-data')),
    (Get-TestGame 'wreckfest-gog' 30GB),
    (Get-TestGame 'wreckfest-steam' 30GB),
    (Get-TestGame 'wreckfest-gog-dlc1' 1MB @() @() @('wreckfest-gog')),
    (Get-TestGame 'doom3-data-gog' 2GB @() @('doom3-data-steam', 'doom3xp-data-steam')),
    (Get-TestGame 'doom3-data-steam' 1.5GB @() @('doom3-data-gog')),
    (Get-TestGame 'doom3xp-data-steam' 500MB @() @('doom3-data-gog') @('doom3-data-steam')),
    (Get-TestGame 'quake3-data-gog' 800MB @() @('quake3-data-steam')),
    (Get-TestGame 'quake3-data-steam' 800MB @() @('quake3-data-gog'))
)
$sel = Select-GamePackage -Packages $catalog -Installed @('quake3-data-steam') -Available 1TB -Total 2TB -ReservePercent 20 -ExcludePattern $GamesExcludePattern
$installNames = @($sel.Install | ForEach-Object { $_.Name })
Assert-True ($sel.Keep -contains 'quake3-data-steam' -and $installNames -notcontains 'quake3-data-gog') 'an installed alternative is kept, not replaced'
Assert-True ($installNames -notcontains 'crossdock') 'tools are excluded from the games'
Assert-True ($installNames -contains 'ut2004-data-gog' -and $installNames -notcontains 'ut2004-data-steam' -and $installNames -notcontains 'ut2004-data-archiveorg') 'GOG wins a declared conflict'
Assert-True ($installNames -contains 'wreckfest-gog' -and $installNames -notcontains 'wreckfest-steam') 'GOG wins between same-named sources'
Assert-True ($installNames -contains 'wreckfest-gog-dlc1') 'the DLC of the chosen GOG game installs'
Assert-True ($installNames -contains 'doom3-data-gog' -and $installNames -notcontains 'doom3xp-data-steam') 'a package conflicting with the chosen alternative is skipped'
Assert-True ($installNames.IndexOf('ut2004-data-gog') -lt $installNames.IndexOf('ut2004-bin')) 'providers install before what needs them'
Assert-True ((@($sel.Install | Where-Object Name -eq 'ut2004-bin')[0].Needs -join ',') -eq 'ut2004-data-gog') 'ut2004-bin records the provider it needs'
$sel = Select-GamePackage -Packages $catalog -Installed @() -Available 40GB -Total 50GB -ReservePercent 20 -ExcludePattern $GamesExcludePattern
$installNames = @($sel.Install | ForEach-Object { $_.Name })
Assert-True ($installNames -notcontains 'wreckfest-gog' -and $installNames -notcontains 'wreckfest-gog-dlc1') 'the largest game and its DLC are dropped to keep 20% free'
Assert-True (($sel.Skip | Where-Object Name -eq 'wreckfest-steam').Reason -match 'alternative to wreckfest-gog') 'the Steam alternative is not substituted for a dropped GOG game'
Assert-True ((40GB - $sel.Need) -ge $sel.Reserve) 'the selection leaves the reserve free'
$sel = Select-GamePackage -Packages $catalog -Installed @() -Available 1GB -Total 100GB -ReservePercent 20 -ExcludePattern $GamesExcludePattern
Assert-True ($sel.Install.Count -eq 0) 'nothing installs when the reserve is already used up'
$sel = Select-GamePackage -Packages @((Get-TestGame 'cro-mag-rally-net-bin' 100MB @('cro-mag-rally') @('cro-mag-rally-net'))) -Installed @('cro-mag-rally-net') -Available 1TB -Total 2TB -ReservePercent 20
Assert-True ($sel.Install.Count -eq 0 -and $sel.Skip[0].Reason -match 'conflicts with installed cro-mag-rally-net') 'a conflict with an installed non-repo package skips the game'
$sel = Select-GamePackage -Packages @((Get-TestGame 'wreckfest-gog' 30GB)) -Installed @('wreckfest-steam') -Available 1TB -Total 2TB -ReservePercent 20
Assert-True ($sel.Install.Count -eq 0 -and $sel.Skip[0].Reason -eq 'alternative to installed wreckfest-steam') 'an installed source the repo no longer publishes keeps its game'
$sel = Select-GamePackage -Packages @((Get-TestGame 'game-b' 1GB)) -Installed @('old-tool') -InstalledSpecs @([pscustomobject]@{ Name = 'old-tool'; Provides = @(); Conflicts = @('game-b') }) -Available 1TB -Total 2TB -ReservePercent 20
Assert-True ($sel.Install.Count -eq 0 -and $sel.Skip[0].Reason -eq 'conflicts with installed old-tool') "an installed package's own conflicts count even when the repo dropped it"
$sel = Select-GamePackage -Packages @((Get-TestGame 'mystery-gog' -1), (Get-TestGame 'small-gog' 1GB)) -Installed @() -Available 1TB -Total 2TB -ReservePercent 20
Assert-True ((@($sel.Install | ForEach-Object { $_.Name }) -join ',') -eq 'small-gog' -and $sel.Skip[0].Reason -match 'size unknown') 'a game without a known size is skipped, not counted as free'
Assert-True ((Compare-GooGetVersion -Left '1.2.10@1' -Right '1.2.9@5') -eq 1) 'googet versions compare numerically'
Assert-True ((Compare-GooGetVersion -Left '1.0.0@2' -Right '1.0.0@1') -eq 1 -and (Compare-GooGetVersion -Left '3369.0.0@5' -Right '3369.0.0@5') -eq 0) 'the release breaks ties'
Assert-True ((Compare-GooGetVersion -Left '2.1' -Right '1.9.9') -eq -1) 'a short version fills from the left, as goolib does (2.1 is 0.2.1)'
Assert-True ((Get-GooGetArchPreference -Architecture 'ARM64') -join ',' -eq 'arm64,x86_64,x86_32,noarch') 'ARM64 prefers arm64, then emulated x86'
$index = @(
    [pscustomobject]@{ Source = 'a'; PackageSpec = [pscustomobject]@{ Name = 'quake3e'; Arch = 'x86_64' } },
    [pscustomobject]@{ Source = 'b'; PackageSpec = [pscustomobject]@{ Name = 'quake3e'; Arch = 'arm64' } },
    [pscustomobject]@{ Source = 'c'; PackageSpec = [pscustomobject]@{ Name = 'dhewm3'; Arch = 'x86_32' } },
    [pscustomobject]@{ Source = 'd'; PackageSpec = [pscustomobject]@{ Name = 'tool'; Arch = 'arm' } }
)
$picked = @(Select-GooGetIndexEntry -Index $index -Archs (Get-GooGetArchPreference -Architecture 'ARM64'))
Assert-True ((($picked | ForEach-Object { $_.Source }) -join ',') -eq 'b,c') 'one index entry per name in the best installable architecture'
$picked = @(Select-GooGetIndexEntry -Index $index -Archs (Get-GooGetArchPreference -Architecture 'AMD64'))
Assert-True ((($picked | ForEach-Object { $_.Source }) -join ',') -eq 'a,c') 'x64 machines take x86_64 then x86_32'
$index = @(
    [pscustomobject]@{ Source = 'old-x64'; PackageSpec = [pscustomobject]@{ Name = 'game'; Arch = 'x86_64'; Version = '1.0.0@1' } },
    [pscustomobject]@{ Source = 'new-noarch'; PackageSpec = [pscustomobject]@{ Name = 'game'; Arch = 'noarch'; Version = '1.1.0@1' } },
    [pscustomobject]@{ Source = 'newer-rel'; PackageSpec = [pscustomobject]@{ Name = 'data'; Arch = 'noarch'; Version = '2.0.0@3' } },
    [pscustomobject]@{ Source = 'older-rel'; PackageSpec = [pscustomobject]@{ Name = 'data'; Arch = 'noarch'; Version = '2.0.0@2' } }
)
$picked = @(Select-GooGetIndexEntry -Index $index -Archs (Get-GooGetArchPreference -Architecture 'AMD64'))
Assert-True ((($picked | ForEach-Object { $_.Source }) -join ',') -eq 'new-noarch,newer-rel') 'the newest version wins before the architecture, as googet installs it'
Write-Output 'GAMES SELECTION PASSED'

# --- GooGet: build inputs, googet.conf and the repo file ---------------------
$sha = '56b678a6e6249ecae2a6b89f35686e6080e85358'
$source = Select-GooGetSource -Commit $sha -GoMod "module github.com/google/googet/v2`n`ngo 1.26.0`n" -GooSpec '{{$version := "3.4.1@0" -}}'
Assert-True ($source.Module -eq 'github.com/google/googet/v2' -and $source.Version -eq '3.4.1@0' -and $source.Commit -eq $sha) 'GooGet source reads module and version from the commit'
$source = Select-GooGetSource -Commit $sha -GoMod "module github.com/google/googet/v3`r`n" -GooSpec '{{$version := "4.0.0" -}}'
Assert-True ($source.Module -eq 'github.com/google/googet/v3' -and $source.Version -eq '4.0.0') 'GooGet follows a module major-version bump'
Assert-True ($source.Repo -eq 'google/googet') 'GooGet source defaults to upstream'
$source = Select-GooGetSource -Repo 'jm2/googet' -Commit $sha -GoMod "module github.com/google/googet/v2`n" -GooSpec '{{$version := "3.4.2@0" -}}'
Assert-True ($source.Repo -eq 'jm2/googet' -and $source.Module -eq 'github.com/google/googet/v2') 'a fork commit keeps the upstream module path'
Assert-True ($GooGetPatchedCommit -match '^[0-9a-f]{40}$' -and $GooGetPatchedRepo -eq 'jm2/googet' -and @($GooGetPatchedPulls).Count -gt 0) 'the patched GooGet build is pinned to a full commit id'
Assert-True (Test-GooGetPatchPending -Merged @($false, $false)) 'patched build while no PR is merged'
Assert-True (Test-GooGetPatchPending -Merged @($true, $false)) 'patched build while one PR is still open'
Assert-True (Test-GooGetPatchPending -Merged @($true)) 'patched build when a PR state is missing'
Assert-True (-not (Test-GooGetPatchPending -Merged @($true, $true))) 'upstream head once every PR is merged'
foreach ($case in @(
        @{ Commit = 'main'; GoMod = 'module github.com/google/googet/v2'; GooSpec = '$version := "1.0.0"' },
        @{ Commit = $sha; GoMod = 'module example.com/other'; GooSpec = '$version := "1.0.0"' },
        @{ Commit = $sha; GoMod = 'module github.com/google/googet/v2'; GooSpec = 'no version here' })) {
    $threw = $false
    try { Select-GooGetSource @case | Out-Null } catch { $threw = $true }
    Assert-True $threw "GooGet source rejects commit '$($case.Commit)' / '$($case.GoMod)' / '$($case.GooSpec)'"
}
Assert-True ((Get-GooGetConfText -Text '') -eq "allowunsafeurl: true`n") 'empty googet.conf gains allowunsafeurl'
Assert-True ((Get-GooGetConfText -Text "proxyserver: http://p:3128`r`nallowunsafeurl: false`r`n") -eq "proxyserver: http://p:3128`nallowunsafeurl: true`n") 'googet.conf keeps other keys and flips allowunsafeurl'
$conf = Get-GooGetConfText -Text "archs: [x86_64]`n"
Assert-True ((Get-GooGetConfText -Text $conf) -eq $conf) 'googet.conf rewrite is idempotent'
Assert-True ((Get-GooGetRepoFileText) -eq "- name: game-packages`n  url: http://192.168.1.11:8080/goo/game-packages`n") 'repo file matches what googet addrepo writes'
$retiredRoot = Join-Path ([IO.Path]::GetTempPath()) ("goo-retired-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $retiredRoot 'repos') | Out-Null
try {
    $retiredFile = Join-Path (Join-Path $retiredRoot 'repos') 'linux-packages.repo'
    Assert-True (@(Get-GooGetRetiredRepoFile -Root $retiredRoot).Count -eq 0) 'no retired repo file when none exists'
    [IO.File]::WriteAllText($retiredFile, "- name: linux-packages`n  url: http://192.168.1.11:8080/goo/linux-packages`n")
    $found = @(Get-GooGetRetiredRepoFile -Root $retiredRoot)
    Assert-True ($found.Count -eq 1 -and $found[0].Name -eq 'linux-packages' -and $found[0].Path -eq $retiredFile) 'the linux-packages repo file this script wrote is found for removal'
    [IO.File]::WriteAllText($retiredFile, "- name: linux-packages`n  url: http://example.invalid/goo`n")
    Assert-True (@(Get-GooGetRetiredRepoFile -Root $retiredRoot).Count -eq 0) 'a hand-made linux-packages repo file is left alone'
    [IO.File]::WriteAllText($retiredFile, "- name: linux-packages`n  url: http://192.168.1.11:8080/goo/LINUX-packages`n")
    Assert-True (@(Get-GooGetRetiredRepoFile -Root $retiredRoot).Count -eq 0) 'a repo file differing only in case is left alone'
}
finally { Remove-Item -LiteralPath $retiredRoot -Recurse -Force }
$installAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-GooGet' }, $true).Extent.Text
Assert-True ($installAst -match 'rev-parse HEAD' -and $installAst -match 'build -mod=readonly') 'a fork checkout is verified against its commit id and built read-only'
Assert-True ($installAst.IndexOf('Initialize-GooGetRoot') -ge 0 -and $installAst.IndexOf('Initialize-GooGetRoot') -lt $installAst.IndexOf('Copy-Item')) 'GooGet root is locked before googet.exe is copied in'
$syncAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sync-GooGetConfiguration' }, $true).Extent.Text
Assert-True ($syncAst.IndexOf('Initialize-GooGetRoot') -ge 0 -and $syncAst.IndexOf('Initialize-GooGetRoot') -lt $syncAst.IndexOf('machine PATH')) 'GooGet root is validated before it joins the machine PATH'
$initAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-GooGetRoot' }, $true).Extent.Text
Assert-True ($initAst -match 'refusing to use') 'an untrusted GooGet root is refused'
Assert-True ($scriptText -notmatch 'icacls') 'GooGet never repairs ACLs in place (icacls /T and /setowner follow junctions)'
Assert-True ($GooGetAclTrustedSids.Count -eq 2 -and $GooGetAclTrustedSids -contains 'S-1-5-32-544' -and $GooGetAclTrustedSids -contains 'S-1-5-18') 'only Administrators and SYSTEM may own or write in the GooGet root'
$walkAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GooGetTreeItem' }, $true).Extent.Text
Assert-True ($walkAst -match 'ReparsePoint') 'the GooGet tree walk does not descend into reparse points'
foreach ($writable in @(0x40000000, 0x10000000, (0x40000000 + 0x20000), 0x2, 0x4, 0x10000, 0x40, 0x40000, 0x80000, 0x1301BF, 0x1F01FF, ([int]::MinValue + 0x40000000))) {
    Assert-True (Test-GooGetWriteRight -Rights $writable) ("access mask 0x{0:X} counts as write" -f $writable)
}
# 2147483648 is GENERIC_READ; [int]::MinValue is the same bit as an Int32
# FileSystemRights value delivers it (sign-extended when widened).
foreach ($readOnly in @(0x1200A9, 0x120089, [long]2147483648, [int]::MinValue, ([long]2147483648 + 0x1200A9), 0x20000000, 0x100000)) {
    Assert-True (-not (Test-GooGetWriteRight -Rights $readOnly)) ("access mask 0x{0:X} is read-only" -f $readOnly)
}
Write-Output 'GOOGET PASSED'

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

# --- An installer-technology change is upgraded by uninstall + install --------
# The mock tracks whether the package is still listed; `list --details` reports
# an ARP entry only when $script:ArpDetails is set.
$script:ArpDetails = $false
$script:UninstallExit = 0
$script:InstallExit = 0
$statefulWinget = {
    $script:WingetCalls += ($args -join '|')
    switch ($args[0]) {
        'upgrade' { $global:LASTEXITCODE = 0x8A15008E }
        'uninstall' { if ($script:UninstallExit -eq 0) { $script:PackageListed = $false }; $global:LASTEXITCODE = $script:UninstallExit }
        'install' { $global:LASTEXITCODE = $script:InstallExit }
        'list' {
            if ($args -contains '--details') {
                if ($script:ArpDetails) { 'LLVM [LLVM.LLVM]'; 'Local Identifier: ARP\Machine\X86\LLVM'; 'Installer Category: exe' }
                $global:LASTEXITCODE = 0
            }
            else { $global:LASTEXITCODE = if ($script:PackageListed) { 0 } else { 0x8A150014 } }
        }
        default { $global:LASTEXITCODE = 0 }
    }
}
Set-Item -Path function:global:winget -Value $statefulWinget
$savedUninstallWait = $WingetUninstallWaitSeconds
$savedUninstallPoll = $WingetUninstallPollSeconds
$WingetUninstallWaitSeconds = 0
$WingetUninstallPollSeconds = 0
$savedTestNsis = ${function:Test-NsisExecutable}
$savedInvokeUninstall = ${function:Invoke-UninstallCommand}
try {
    $script:WingetCalls = @(); $script:PackageListed = $true
    $result = Invoke-WingetPackageSet -InstalledIds @('LLVM.LLVM') -DesiredIds @('LLVM.LLVM') 3>$null 6>$null
    $verbs = @($script:WingetCalls | ForEach-Object { ($_ -split '\|')[0] } | Where-Object { $_ -ne 'list' })
    Assert-True (($verbs -join ',') -eq 'upgrade,uninstall,install') "an installer-technology mismatch reinstalls (got $($verbs -join ','))"
    Assert-True ($result.UpdatedOrCurrent -contains 'LLVM.LLVM' -and $result.Failed.Count -eq 0) 'a successful reinstall counts as updated'

    # Upgrade-not-supported from the reinstall's install means nothing was
    # installed; it is not the self-updating 'current' of a plain upgrade.
    $script:WingetCalls = @(); $script:PackageListed = $true; $script:InstallExit = $WingetSelfUpdatingCode
    $result = Invoke-WingetPackageSet -InstalledIds @('LLVM.LLVM') -DesiredIds @('LLVM.LLVM') 3>$null 6>$null
    Assert-True ($result.Failed -contains 'upgrade LLVM.LLVM' -and $result.UpdatedOrCurrent -notcontains 'LLVM.LLVM') 'upgrade-not-supported after a reinstall is a failure'
    $script:InstallExit = 0

    $script:WingetCalls = @(); $script:PackageListed = $true; $script:UninstallExit = 1
    $result = Invoke-WingetPackageSet -InstalledIds @('LLVM.LLVM') -DesiredIds @('LLVM.LLVM') 3>$null 6>$null
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like 'install|*' }).Count -eq 0) 'a failed uninstall does not attempt the reinstall'
    Assert-True ($result.Failed -contains 'upgrade LLVM.LLVM') 'a failed uninstall is reported as a failed upgrade'

    # An uninstaller that returns while the package stays listed (an NSIS
    # relaunch still running or waiting) does not get a reinstall on top.
    function global:winget {
        $script:WingetCalls += ($args -join '|')
        $global:LASTEXITCODE = if ($args[0] -eq 'upgrade') { 0x8A15008E } else { 0 }
    }
    $script:WingetCalls = @()
    $result = Invoke-WingetPackageSet -InstalledIds @('LLVM.LLVM') -DesiredIds @('LLVM.LLVM') 3>$null 6>$null
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like 'install|*' }).Count -eq 0) 'a package still listed after its uninstaller returns is not reinstalled'
    Assert-True ($result.Failed -contains 'upgrade LLVM.LLVM') 'a package still listed after uninstall is reported as a failed upgrade'
}
finally {
    $WingetUninstallWaitSeconds = $savedUninstallWait
    $WingetUninstallPollSeconds = $savedUninstallPoll
    Remove-Item -Path function:global:winget -ErrorAction SilentlyContinue
}

# NSIS uninstallers registered without a quiet command run with /S directly.
Set-Item -Path function:Get-ItemProperty -Value {
    param([string]$LiteralPath)
    [pscustomobject]@{ PSPath = $LiteralPath; UninstallString = '"C:\Program Files\LLVM\Uninstall.exe"'; QuietUninstallString = '' }
}
$script:UninstallInvocations = @()
function Test-NsisExecutable { param($Path) $Path -eq 'C:\Program Files\LLVM\Uninstall.exe' }
function Invoke-UninstallCommand { param($FilePath, $Arguments) $script:UninstallInvocations += "$FilePath|$Arguments"; $script:PackageListed = $false; 0 }
Set-Item -Path function:global:winget -Value $statefulWinget
try {
    $script:ArpDetails = $true
    $script:WingetCalls = @(); $script:PackageListed = $true
    $entry = Get-WingetArpEntry -Id 'LLVM.LLVM'
    Assert-True ($null -ne $entry) 'the ARP entry is found from winget list --details'
    Assert-True (Remove-WingetPackageForReinstall -Id 'LLVM.LLVM' 6>$null) 'the NSIS uninstall is accepted'
    Assert-True (($script:UninstallInvocations -join ';') -eq 'C:\Program Files\LLVM\Uninstall.exe|/S') "the NSIS uninstaller runs with /S (got $($script:UninstallInvocations -join ';'))"
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like 'uninstall|*' }).Count -eq 0) 'winget uninstall is not used for an NSIS uninstaller'
}
finally {
    Remove-Item -Path function:Get-ItemProperty -ErrorAction SilentlyContinue
    Set-Item -Path function:Test-NsisExecutable -Value $savedTestNsis
    Set-Item -Path function:Invoke-UninstallCommand -Value $savedInvokeUninstall
    Remove-Item -Path function:global:winget -ErrorAction SilentlyContinue
}
Write-Output 'INSTALLER TECHNOLOGY CHANGE PASSED'

# --- A package hosting the run is never upgraded by it ----------------------
$script:WingetCalls = @()
function global:winget { $script:WingetCalls += ($args -join '|'); $global:LASTEXITCODE = 0 }
try {
    $result = Invoke-WingetPackageSet -InstalledIds @('Example.Host', 'Git.Git') -DesiredIds @('Example.Host', 'Git.Git') -HostIds @('Example.Host') 6>$null
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like '*Example.Host*' }).Count -eq 0) 'the hosting package is not upgraded'
    Assert-True (@($script:WingetCalls | Where-Object { $_ -like 'upgrade|--id|Git.Git|*' }).Count -eq 1) 'other packages are still upgraded'
    Assert-True ($result.HostSkipped -contains 'Example.Host' -and $result.Failed.Count -eq 0) 'the skipped host update is reported, not failed'

    # Per-package extra arguments reach every install/upgrade of that package;
    # other packages get no extra arguments (not even an empty one).
    $savedPackageArgs = $WingetPackageArgs
    $WingetPackageArgs = @{ 'Example.Extra' = @('--custom', 'A=1') }
    $script:WingetCalls = @()
    Invoke-WingetPackageSet -InstalledIds @('Example.Extra', 'Git.Git') -DesiredIds @('Example.Extra', 'Git.Git') 6>$null | Out-Null
    Assert-True ($script:WingetCalls -contains 'upgrade|--id|Example.Extra|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity|--custom|A=1') 'per-package arguments reach the upgrade'
    Assert-True ($script:WingetCalls -contains 'upgrade|--id|Git.Git|--exact|--source|winget|--include-unknown|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity') 'other upgrades carry no extra arguments'
    $script:WingetCalls = @()
    Invoke-WingetPackageSet -InstalledIds @('Example.Unrelated') -DesiredIds @('Example.Extra') 6>$null | Out-Null
    Assert-True ($script:WingetCalls -contains 'install|--id|Example.Extra|--exact|--source|winget|--no-upgrade|--silent|--accept-package-agreements|--accept-source-agreements|--disable-interactivity|--custom|A=1') 'per-package arguments reach the install'
    $WingetPackageArgs = $savedPackageArgs
}
finally {
    Remove-Item -Path function:global:winget -ErrorAction SilentlyContinue
}
Write-Output 'HOST PACKAGE PASSED'

# --- winget launch failures are retried, exit codes are not ------------------
$savedRetrySeconds = $WingetLaunchRetrySeconds
$WingetLaunchRetrySeconds = 0
$script:WingetLaunches = 0
function global:winget {
    $script:WingetLaunches++
    if ($script:WingetLaunches -eq 1) {
        throw [System.Management.Automation.ApplicationFailedException]::new("Program 'winget.exe' failed to run: Access is denied")
    }
    $global:LASTEXITCODE = 0x8A15002B
}
try {
    Invoke-Winget upgrade --id Git.Git 3>$null | Out-Null
    Assert-True ($script:WingetLaunches -eq 2) 'a winget launch failure is retried once winget can start'
    Assert-True ($LASTEXITCODE -eq 0x8A15002B) 'the exit code of the retried winget passes through'
    $script:WingetLaunches = 1
    Invoke-Winget upgrade --id Git.Git 3>$null | Out-Null
    Assert-True ($script:WingetLaunches -eq 2) 'a winget non-zero exit code is not retried'
    function global:winget { $script:WingetLaunches++; throw [System.Management.Automation.ApplicationFailedException]::new('Access is denied') }
    $script:WingetLaunches = 0
    $threw = $false
    try { Invoke-Winget upgrade --id Git.Git 3>$null | Out-Null } catch { $threw = $true }
    Assert-True ($threw -and $script:WingetLaunches -eq $WingetLaunchAttempts) 'a persistent winget launch failure throws after the last attempt'
}
finally {
    $WingetLaunchRetrySeconds = $savedRetrySeconds
    Remove-Item -Path function:global:winget -ErrorAction SilentlyContinue
}
Write-Output 'WINGET LAUNCH RETRY PASSED'

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
$balunApp = $ReleaseApps | Where-Object Name -eq 'Balun'
function Get-ReleaseAppInstall { param($App) $script:QueriedApp = $App.Name; return $script:BalunExisting }
function Get-ReleaseAppRelease { param($App) $script:BalunCalls += "release|$($App.Name)"; [pscustomobject]@{ Version = '0.2.0'; Name = ($App.AssetFormat -f 'x86_64'); Url = 'u'; Sha256 = 'a' * 64 } }
function Install-ReleaseAppFromRelease { param($App, $Release) $script:BalunCalls += "release-install|$($Release.Version)"; $script:InstalledApp = $App.Name }
function Invoke-BalunCase {
    param([bool]$Winget, $Existing, [string[]]$InstalledIds, [bool]$NoUpgrade, $App = $balunApp)
    $script:BalunCalls = @(); $script:BalunWinget = $Winget; $script:BalunExisting = $Existing
    return (Invoke-ReleaseAppStep -App $App -InstalledIds $InstalledIds -NoUpgrade:$NoUpgrade 6>$null 3>$null)
}
try {
    $old = [pscustomobject]@{ Version = '0.1.1'; Key = '{3B7A0CD1-33F6-5D60-9973-2B7A1B53E02A}_is1' }
    $status = Invoke-BalunCase $true $null @() $false
    Assert-True ($status -eq 'installed') "WinGet installs Balun when the ID resolves (got $status)"
    Assert-True (@($script:BalunCalls | Where-Object { $_ -like 'install|--id|jm2.Balun|*' }).Count -eq 1) 'WinGet install of jm2.Balun'
    Assert-True ($script:BalunCalls -notcontains 'release|Balun') 'no release fallback when WinGet resolves'

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
    Assert-True ($status -eq 'current' -and $script:BalunCalls -notcontains 'release|Balun') '-NoUpgrade skips the release lookup for an installed Balun'

    $status = Invoke-BalunCase $false ([pscustomobject]@{ Version = '0.2.0'; Key = 'k' }) @() $false
    Assert-True ($status -eq 'current' -and $script:BalunCalls -notcontains 'release-install|0.2.0') 'matching release version is current'

    $status = Invoke-BalunCase $false $old @() $false
    Assert-True ($status -eq 'updated' -and $script:BalunCalls -contains 'release-install|0.2.0') 'older release install is updated from the release'

    $script:BalunWingetExit = 1
    $status = Invoke-BalunCase $true $null @() $false
    Assert-True ($status -eq 'failed') 'WinGet failure is reported'
    $script:BalunWingetExit = 0

    $transomApp = $ReleaseApps | Where-Object Name -eq 'Transom'
    $status = Invoke-BalunCase $true $null @() $false $transomApp
    Assert-True ($status -eq 'installed' -and @($script:BalunCalls | Where-Object { $_ -like 'install|--id|jm2.Transom|*' }).Count -eq 1) 'WinGet installs jm2.Transom when the ID resolves'
    $status = Invoke-BalunCase $false $null @() $false $transomApp
    Assert-True ($status -eq 'installed' -and $script:BalunCalls -contains 'release|Transom' -and $script:BalunCalls -contains 'release-install|0.2.0') 'Transom falls back to its own release'
    Assert-True ($script:QueriedApp -eq 'Transom' -and $script:InstalledApp -eq 'Transom') 'Transom install state and installer are its own'
}
finally {
    Remove-Item -Path function:global:winget -ErrorAction SilentlyContinue
}

# Release resolution cross-checks SHA256SUMS.txt against the GitHub digest.
${function:Get-ReleaseAppRelease} = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ReleaseAppRelease'
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
    $release = Get-ReleaseAppRelease -App $balunApp
    Assert-True ($release.Name -eq 'balun-windows-x86_64-setup.exe' -and $release.Sha256 -eq $sum -and $release.Version -eq '0.2.0') 'release asset and checksum resolved for x86_64'
    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    $threw = $false
    try { Get-ReleaseAppRelease -App $balunApp | Out-Null } catch { $threw = $_.Exception.Message -match 'lacks exactly one' }
    Assert-True $threw 'aarch64 host selects the aarch64 asset (absent in this fixture)'
    $env:PROCESSOR_ARCHITEW6432 = $null
    $script:ReleaseDigest = "sha256:$('e' * 64)"
    $threw = $false
    try { Get-ReleaseAppRelease -App $balunApp | Out-Null } catch { $threw = $_.Exception.Message -match 'disagrees' }
    Assert-True $threw 'digest/SHA256SUMS disagreement is rejected'
    $script:ReleaseDigest = ''
    Assert-True ((Get-ReleaseAppRelease -App $balunApp).Sha256 -eq $sum) 'missing GitHub digest falls back to SHA256SUMS.txt alone'
}
finally {
    $env:PROCESSOR_ARCHITECTURE = $savedArch; $env:PROCESSOR_ARCHITEW6432 = $savedWow
    Remove-Item -Path function:Invoke-RestMethod, function:Invoke-WebRequest -ErrorAction SilentlyContinue
}
Write-Output 'BALUN PASSED'

# --- Ventoy: verified GitHub release zip ------------------------------------
$ventoySum = 'a' * 64
$script:VentoyDigest = "sha256:$ventoySum"
$script:VentoyTag = 'v1.1.18'
$script:VentoyUrl = 'https://github.com/ventoy/Ventoy/releases/download/v1.1.18/ventoy-1.1.18-windows.zip'
Set-Item -Path function:Invoke-RestMethod -Value {
    [pscustomobject]@{
        tag_name = $script:VentoyTag; prerelease = $false; draft = $false
        assets = @(
            [pscustomobject]@{ name = 'ventoy-1.1.18-linux.tar.gz'; browser_download_url = 'linux'; digest = "sha256:$('b' * 64)" }
            [pscustomobject]@{ name = 'ventoy-1.1.18-windows.zip'; browser_download_url = $script:VentoyUrl; digest = $script:VentoyDigest }
            [pscustomobject]@{ name = 'sha256.txt'; browser_download_url = 'sums'; digest = '' }
        )
    }
}
Set-Item -Path function:Invoke-WebRequest -Value {
    $outFile = $args[[Array]::IndexOf([object[]]$args, '-OutFile') + 1]
    Set-Content -LiteralPath $outFile -NoNewline -Value "$('b' * 64)  ventoy-1.1.18-linux.tar.gz`n$ventoySum  ventoy-1.1.18-windows.zip`n"
}
try {
    $release = Get-VentoyRelease
    Assert-True ($release.Version -eq '1.1.18' -and $release.Name -eq 'ventoy-1.1.18-windows.zip' -and $release.Sha256 -eq $ventoySum -and $release.Url -eq $script:VentoyUrl) 'Ventoy release zip and checksum resolved'
    $script:VentoyDigest = "sha256:$('e' * 64)"
    $threw = $false
    try { Get-VentoyRelease | Out-Null } catch { $threw = $_.Exception.Message -match 'disagrees' }
    Assert-True $threw 'Ventoy digest/sha256.txt disagreement is rejected'
    $script:VentoyDigest = "sha256:$ventoySum"
    $script:VentoyTag = 'v1.1.18-beta'
    $threw = $false
    try { Get-VentoyRelease | Out-Null } catch { $threw = $_.Exception.Message -match 'unsupported tag' }
    Assert-True $threw 'non-X.Y.Z Ventoy tags are rejected'
    $script:VentoyTag = 'v1.1.18'
    $script:VentoyUrl = 'https://example.invalid/ventoy-1.1.18-windows.zip'
    $threw = $false
    try { Get-VentoyRelease | Out-Null } catch { $threw = $_.Exception.Message -match 'outside the expected' }
    Assert-True $threw 'a Ventoy asset outside its release download path is rejected'
}
finally {
    Remove-Item -Path function:Invoke-RestMethod, function:Invoke-WebRequest -ErrorAction SilentlyContinue
}

# Install: unpack, put the native Ventoy2Disk beside the x86 one, keep the
# saved settings, record the release, and swap the tree in.
$ventoyTemp = Join-Path ([IO.Path]::GetTempPath()) ("ventoy-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$savedProgramFiles = $env:ProgramFiles; $savedArch = $env:PROCESSOR_ARCHITECTURE; $savedWow = $env:PROCESSOR_ARCHITEW6432
try {
    $tree = Join-Path (Join-Path $ventoyTemp 'src') 'ventoy-1.1.18'
    foreach ($sub in 'boot', 'ventoy', 'altexe') { New-Item -ItemType Directory -Force -Path (Join-Path $tree $sub) | Out-Null }
    Set-Content -LiteralPath (Join-Path $tree 'Ventoy2Disk.exe') -Value 'x86'
    Set-Content -LiteralPath (Join-Path (Join-Path $tree 'altexe') 'Ventoy2Disk_X64.exe') -Value 'x64'
    Set-Content -LiteralPath (Join-Path (Join-Path $tree 'altexe') 'Ventoy2Disk_ARM64.exe') -Value 'arm64'
    $zip = Join-Path $ventoyTemp 'ventoy-1.1.18-windows.zip'
    Compress-Archive -LiteralPath $tree -DestinationPath $zip
    $zipSum = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    $env:ProgramFiles = Join-Path $ventoyTemp 'pf'
    $root = Join-Path $env:ProgramFiles 'Ventoy'
    New-Item -ItemType Directory -Path $root | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'Ventoy2Disk.exe') -Value 'old'
    Set-Content -LiteralPath (Join-Path $root 'Ventoy2Disk.ini') -Value 'Language=English'
    Set-Content -LiteralPath (Join-Path $root 'log.txt') -Value 'old log'
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'; $env:PROCESSOR_ARCHITEW6432 = $null
    $script:VentoyShortcut = $null
    function Install-StartMenuShortcut { param($Name, $Target, [switch]$AllUsers) $script:VentoyShortcut = "$Name|$Target|$AllUsers" }
    Set-Item -Path function:Invoke-WebRequest -Value {
        $outFile = $args[[Array]::IndexOf([object[]]$args, '-OutFile') + 1]
        Copy-Item -LiteralPath $zip -Destination $outFile
    }
    $ventoyRelease = [pscustomobject]@{ Version = '1.1.18'; Name = 'ventoy-1.1.18-windows.zip'; Url = 'u'; Sha256 = $zipSum }
    Install-Ventoy -Release $ventoyRelease
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'Ventoy2Disk.exe')) -eq 'x86') 'Ventoy tree replaced from the release'
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'Ventoy2Disk_X64.exe')) -eq 'x64') 'native x64 Ventoy2Disk placed beside the x86 one'
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'Ventoy2Disk.ini')) -eq 'Language=English') 'Ventoy2Disk settings carried over'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'log.txt'))) 'other files from the previous tree are dropped'
    Assert-True ((Get-VentoyShortcutTarget) -eq (Join-Path $root 'Ventoy2Disk_X64.exe')) 'Start menu shortcut targets the native build'
    Assert-True (-not (Test-Path -LiteralPath "$root.lan-ipxe-new") -and -not (Test-Path -LiteralPath "$root.lan-ipxe-old")) 'no staging or previous tree left behind'
    $installed = Get-VentoyInstall
    Assert-True ($installed.Version -eq '1.1.18' -and $installed.Sha256 -eq $zipSum) 'installed Ventoy release recorded'

    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    Remove-Item -LiteralPath (Join-Path (Join-Path $tree 'altexe') 'Ventoy2Disk_ARM64.exe')
    Move-Item -LiteralPath $zip -Destination "$zip.orig"
    Compress-Archive -LiteralPath $tree -DestinationPath $zip
    $noArm = [pscustomobject]@{ Version = '1.1.18'; Name = 'ventoy-1.1.18-windows.zip'; Url = 'u'; Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() }
    Install-Ventoy -Release $noArm 3>$null
    Assert-True ((Get-VentoyShortcutTarget) -eq (Join-Path $root 'Ventoy2Disk.exe')) 'a release without the native build falls back to the x86 Ventoy2Disk'
    $env:PROCESSOR_ARCHITEW6432 = $null
    Move-Item -LiteralPath "$zip.orig" -Destination $zip -Force
    Install-Ventoy -Release $ventoyRelease

    $bad = [pscustomobject]@{ Version = '1.1.19'; Name = 'ventoy-1.1.19-windows.zip'; Url = 'u'; Sha256 = 'f' * 64 }
    $threw = $false
    try { Install-Ventoy -Release $bad } catch { $threw = $_.Exception.Message -match 'checksum mismatch' }
    Assert-True ($threw -and (Get-VentoyInstall).Version -eq '1.1.18') 'a checksum mismatch leaves the installed Ventoy untouched'

    # An interrupted swap that left only the previous tree is put back, not
    # deleted as stale.
    Rename-Item -LiteralPath $root -NewName 'Ventoy.lan-ipxe-old'
    Restore-InterruptedTreeSwap -Root $root -Label 'Ventoy'
    Assert-True ((Get-VentoyInstall).Version -eq '1.1.18' -and -not (Test-Path -LiteralPath "$root.lan-ipxe-old")) 'previous tree restored after an interrupted swap'

    # Step decisions.
    $script:VentoyCalls = @()
    function Get-VentoyRelease { $script:VentoyCalls += 'release'; return $ventoyRelease }
    function Install-Ventoy { param($Release) $script:VentoyCalls += "install|$($Release.Version)" }
    $script:VentoyShortcut = $null
    Assert-True ((Invoke-VentoyStep 3>$null) -eq 'current' -and $script:VentoyCalls -notcontains 'install|1.1.18') 'recorded release is current'
    Assert-True ($script:VentoyShortcut -eq "Ventoy2Disk|$(Join-Path $root 'Ventoy2Disk_X64.exe')|True") 'a current Ventoy still gets its all-users Start menu shortcut'
    # A copy unpacked by hand (no marker) is left alone under -NoUpgrade and
    # replaced otherwise.
    $markerPath = Join-Path $root $VentoyMarkerName
    $markerText = Get-Content -Raw -LiteralPath $markerPath
    # -Force: on Linux CI, PowerShell treats the dot-named marker as hidden.
    Remove-Item -LiteralPath $markerPath -Force
    Assert-True ((Get-VentoyInstall).Managed -eq $false) 'a Ventoy without the marker is reported as unmanaged'
    $script:VentoyCalls = @()
    Assert-True ((Invoke-VentoyStep -NoUpgrade 3>$null) -eq 'current' -and $script:VentoyCalls.Count -eq 0) '-NoUpgrade leaves an unmanaged Ventoy alone'
    Assert-True ((Invoke-VentoyStep 3>$null) -eq 'updated' -and $script:VentoyCalls -contains 'install|1.1.18') 'apply replaces an unmanaged Ventoy'
    Set-Content -LiteralPath $markerPath -Value $markerText -NoNewline
    $script:VentoyCalls = @()
    Assert-True ((Invoke-VentoyStep -NoUpgrade 3>$null) -eq 'current' -and $script:VentoyCalls.Count -eq 0) '-NoUpgrade skips the release lookup for an installed Ventoy'
    $ventoyRelease = [pscustomobject]@{ Version = '1.1.19'; Name = 'ventoy-1.1.19-windows.zip'; Url = 'u'; Sha256 = 'f' * 64 }
    $script:VentoyCalls = @()
    Assert-True ((Invoke-VentoyStep 3>$null) -eq 'updated' -and $script:VentoyCalls -contains 'install|1.1.19') 'newer release replaces Ventoy'
    Remove-Item -LiteralPath $root -Recurse -Force
    $script:VentoyCalls = @()
    Assert-True ((Invoke-VentoyStep 3>$null) -eq 'installed' -and $script:VentoyCalls -contains 'install|1.1.19') 'missing Ventoy is installed'
    function Get-VentoyRelease { throw 'offline' }
    Assert-True ((Invoke-VentoyStep 3>$null) -eq 'failed') 'release lookup failure is reported'
}
finally {
    $env:ProgramFiles = $savedProgramFiles; $env:PROCESSOR_ARCHITECTURE = $savedArch; $env:PROCESSOR_ARCHITEW6432 = $savedWow
    Remove-Item -Path function:Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ventoyTemp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'VENTOY PASSED'

# --- PowerShell 7: the GitHub LTS MSI replaces the Store package -------------
# msiexec results: reboot codes count as success and request a reboot, 1618 is
# retried, 1605 is accepted only where the caller allows it, and any other code
# throws with the log path.
$savedBusyRetry = $MsiBusyRetrySeconds
$MsiBusyRetrySeconds = 0
$script:MsiExitCodes = @()
$script:MsiArgs = @()
Set-Item -Path function:Start-Process -Value {
    $script:MsiArgs += ,@($args[[Array]::IndexOf([object[]]$args, '-ArgumentList') + 1])
    $code = $script:MsiExitCodes[0]
    $script:MsiExitCodes = @($script:MsiExitCodes | Select-Object -Skip 1)
    [pscustomobject]@{ ExitCode = $code }
}
try {
    $script:RebootNeeded = $false
    $script:MsiExitCodes = @(3010)
    Invoke-Msiexec -Arguments @('/i', '"C:\Temp dir\p.msi"', '/quiet') 6>$null
    Assert-True ($script:RebootNeeded) 'msiexec 3010 counts as success and requests a reboot'
    Assert-True (($script:MsiArgs[0] -join ' ') -eq "/i `"C:\Temp dir\p.msi`" /quiet /l*v `"$PowerShellMsiLog`"") 'msiexec gets a quoted package path and a verbose log'
    $script:MsiArgs = @(); $script:MsiExitCodes = @(1618, 1618, 0)
    Invoke-Msiexec -Arguments @('/i', 'p.msi') 6>$null
    Assert-True ($script:MsiArgs.Count -eq 3) 'msiexec 1618 (another install running) is retried'
    $script:MsiExitCodes = @(1605)
    Invoke-Msiexec -Arguments @('/x', '{P}') -ExtraOkCodes @(1605) 6>$null
    $threw = $false
    $script:MsiExitCodes = @(1605)
    try { Invoke-Msiexec -Arguments @('/i', 'p.msi') 6>$null } catch { $threw = $true }
    Assert-True $threw '1605 is accepted only where the caller allows it'
    $threw = $false
    $script:MsiExitCodes = @(1603)
    try { Invoke-Msiexec -Arguments @('/i', 'p.msi') 6>$null } catch { $threw = $_.Exception.Message -like '*exited with 1603 (log: *' }
    Assert-True $threw 'msiexec failure throws with the log path'
}
finally {
    $MsiBusyRetrySeconds = $savedBusyRetry
    $script:RebootNeeded = $false
    Remove-Item -Path function:Start-Process -ErrorAction SilentlyContinue
}

$script:PwshDir = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-msi-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:PwshDir | Out-Null
$script:PwshMsi = Join-Path $script:PwshDir 'pwsh.exe'
$script:PwshCalls = @(); $script:PwshStore = @(); $script:PwshRuns = $true
$script:PwshInstallFails = $false; $script:PwshReleaseFails = $false
$script:PwshExisting = $null; $script:PwshHosted = $false
function Get-PowerShellMsiPath { $script:PwshMsi }
function Get-StorePowerShell { @($script:PwshStore) }
function Test-PowerShellMsiRun { param($Path) $script:PwshCalls += "run|$Path"; $script:PwshRuns }
function Get-PowerShellMsiInstall { $script:PwshExisting }
function Test-PowerShellMsiHost { $script:PwshHosted }
function Get-PowerShellLtsRelease {
    $script:PwshCalls += 'release'
    if ($script:PwshReleaseFails) { throw 'metadata unreachable' }
    [pscustomobject]@{ Version = '7.6.10'; Name = 'PowerShell-7.6.10-win-x64.msi'; Url = 'u'; Sha256 = 'a' * 64 }
}
function Save-PowerShellMsi {
    param($Release)
    $script:PwshCalls += "msi-save|$($Release.Version)"
    $dir = Join-Path $script:PwshDir 'download'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [pscustomobject]@{ Directory = $dir; Path = (Join-Path $dir $Release.Name) }
}
function Install-PowerShellMsi {
    param($Path)
    $script:PwshCalls += "msi-install|$(Split-Path -Leaf $Path)"
    if ($script:PwshInstallFails) { throw 'msiexec /i exited with 1603' }
    Set-Content -LiteralPath $script:PwshMsi -Value ''
}
function Invoke-Msiexec { param([string[]]$Arguments, [int[]]$ExtraOkCodes) $null = $ExtraOkCodes; $script:PwshCalls += "msiexec|$($Arguments -join ' ')" }
Set-Item -Path function:Remove-AppxPackage -Value { $script:PwshCalls += 'remove-appx'; $script:PwshStore = @() }
$script:PwshWarnings = @()
function Invoke-PwshCase {
    param([bool]$HasMsi, [bool]$HasStore, [string]$Version = '7.6.10', [bool]$NoUpgrade = $false,
          [bool]$Registered = $HasMsi, [string]$ProductCode = '{B6950B97-25F0-4EB3-9FC8-DB5D085645DE}')
    $script:PwshCalls = @()
    Remove-Item -LiteralPath $script:PwshMsi -ErrorAction SilentlyContinue
    if ($HasMsi) { Set-Content -LiteralPath $script:PwshMsi -Value '' }
    $script:PwshExisting = $null
    if ($Registered) { $script:PwshExisting = [pscustomobject]@{ Version = $Version; ProductCode = $ProductCode } }
    $script:PwshStore = @(if ($HasStore) { [pscustomobject]@{ Version = '7.6.7.0' } })
    $status = Invoke-PowerShellMsiSwitch -NoUpgrade:$NoUpgrade 6>$null 3>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.WarningRecord]) { $script:PwshWarnings += $_.Message } else { $_ }
    }
    return $status
}
$installMsi = 'msi-install|PowerShell-7.6.10-win-x64.msi'
$uninstallMsi = 'msiexec|/x {B6950B97-25F0-4EB3-9FC8-DB5D085645DE} /quiet /norestart'
try {
    $status = Invoke-PwshCase $false $true
    Assert-True ($status -eq 'installed') "Store-only host gets the LTS MSI (got $status)"
    Assert-True ($script:PwshCalls -contains $installMsi) 'the LTS release MSI is installed'
    Assert-True ([Array]::IndexOf([object[]]$script:PwshCalls, 'remove-appx') -gt [Array]::IndexOf([object[]]$script:PwshCalls, "run|$script:PwshMsi")) 'Store copy is removed only after the MSI runs'

    $status = Invoke-PwshCase $false $false -NoUpgrade $true
    Assert-True ($status -eq 'installed') "-NoUpgrade still installs a missing MSI (got $status)"

    $status = Invoke-PwshCase $true $false
    Assert-True ($status -eq 'current' -and @($script:PwshCalls | Where-Object { $_ -like 'msi*' -or $_ -eq 'remove-appx' }).Count -eq 0) 'current LTS MSI is left alone'

    $status = Invoke-PwshCase $true $false '7.6.11'
    Assert-True ($status -eq 'current' -and @($script:PwshCalls | Where-Object { $_ -like 'msi*' }).Count -eq 0) 'a newer patch of the LTS line (metadata lagging) is kept, not downgraded'

    $status = Invoke-PwshCase $true $false '7.6.7'
    Assert-True ($status -eq 'updated' -and $script:PwshCalls -contains $installMsi) "older LTS patch is updated in place (got $status)"
    Assert-True ($script:PwshCalls -notcontains $uninstallMsi) 'an in-place LTS update uninstalls nothing'

    $status = Invoke-PwshCase $true $false '7.7.0'
    Assert-True ($status -eq 'updated') "newer non-LTS line is switched to LTS (got $status)"
    $save = [Array]::IndexOf([object[]]$script:PwshCalls, 'msi-save|7.6.10')
    $uninstall = [Array]::IndexOf([object[]]$script:PwshCalls, $uninstallMsi)
    Assert-True ($save -ge 0 -and $save -lt $uninstall -and $uninstall -lt [Array]::IndexOf([object[]]$script:PwshCalls, $installMsi)) 'the LTS MSI is verified before the non-LTS MSI is uninstalled, then installed'

    $script:PwshWarnings = @()
    $script:PwshInstallFails = $true
    $status = Invoke-PwshCase $true $false '7.7.0'
    Assert-True ($status -eq 'failed' -and @($script:PwshWarnings | Where-Object { $_ -like '*was uninstalled, but LTS 7.6.10 failed to install*' }).Count -eq 1) 'an install failure after the uninstall says PowerShell 7 is gone'
    $script:PwshInstallFails = $false

    $status = Invoke-PwshCase $true $false '7.7.0' -ProductCode ''
    Assert-True ($status -eq 'failed' -and @($script:PwshCalls | Where-Object { $_ -like 'msi*' }).Count -eq 0) 'a newer line without a ProductCode fails before anything is changed'

    $status = Invoke-PwshCase $false $false '7.6.10' -Registered $true
    Assert-True ($status -eq 'installed' -and [Array]::IndexOf([object[]]$script:PwshCalls, $uninstallMsi) -lt [Array]::IndexOf([object[]]$script:PwshCalls, $installMsi) -and $script:PwshCalls -contains $uninstallMsi) 'a registered install whose files are gone is uninstalled, then reinstalled'

    $status = Invoke-PwshCase $true $false -Registered $false
    Assert-True ($status -eq 'updated' -and $script:PwshCalls -contains $installMsi -and $script:PwshCalls -notcontains $uninstallMsi) 'an unregistered copy is installed over'

    $script:PwshHosted = $true
    $status = Invoke-PwshCase $true $true '7.7.0'
    Assert-True ($status -eq 'host-skipped' -and @($script:PwshCalls | Where-Object { $_ -like 'msi*' }).Count -eq 0) 'the PowerShell hosting the run is not switched'
    Assert-True ($script:PwshCalls -contains 'remove-appx') 'a host-skipped switch still removes the Store copy'
    $script:PwshHosted = $false

    $status = Invoke-PwshCase $true $false '7.6.7' -NoUpgrade $true
    Assert-True ($status -eq 'current' -and $script:PwshCalls -notcontains 'release') '-NoUpgrade skips the release lookup for an installed MSI'

    $status = Invoke-PwshCase $true $true
    Assert-True ($status -eq 'store-removed' -and $script:PwshCalls -contains 'remove-appx') 'leftover Store copy is removed when the MSI exists'

    $script:PwshRuns = $false
    $status = Invoke-PwshCase $true $true
    Assert-True ($status -eq 'failed' -and $script:PwshCalls -notcontains 'remove-appx') 'a broken MSI keeps the Store copy'
    $script:PwshRuns = $true

    $script:PwshInstallFails = $true
    $status = Invoke-PwshCase $false $true
    Assert-True ($status -eq 'failed' -and $script:PwshCalls -notcontains 'remove-appx') 'failed MSI install keeps the Store copy'
    $script:PwshInstallFails = $false

    $script:PwshReleaseFails = $true
    $status = Invoke-PwshCase $true $true '7.6.7'
    Assert-True ($status -eq 'failed' -and $script:PwshCalls -notcontains 'remove-appx') 'an unresolved LTS release fails without touching the Store copy'
    $script:PwshReleaseFails = $false
}
finally {
    Remove-Item -Path function:Remove-AppxPackage -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:PwshDir -Recurse -Force -ErrorAction SilentlyContinue
}

# LTS resolution: the newest stable LTSReleaseTag, then that release's MSI,
# cross-checked against hashes.sha256 and the GitHub digest.
${function:Get-PowerShellLtsRelease} = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PowerShellLtsRelease'
}, $true).Body.GetScriptBlock()
$msiSum = 'f' * 64
$script:LtsTags = @('v7.4.13', 'v7.6.10', 'v7.8.0-preview.1')
$script:RestUris = @()
Set-Item -Path function:Invoke-RestMethod -Value {
    $uri = [string]$args[[Array]::IndexOf([object[]]$args, '-Uri') + 1]
    $script:RestUris += $uri
    if ($uri -like '*metadata.json') { return [pscustomobject]@{ LTSReleaseTag = $script:LtsTags; StableReleaseTag = 'v7.7.0' } }
    [pscustomobject]@{
        tag_name = 'v7.6.10'; prerelease = $false; draft = $false
        assets = @(
            [pscustomobject]@{ name = 'PowerShell-7.6.10-win-x64.msi'; browser_download_url = 'msi'; digest = "sha256:$msiSum" }
            [pscustomobject]@{ name = 'hashes.sha256'; browser_download_url = 'sums'; digest = '' }
        )
    }
}
Set-Item -Path function:Invoke-WebRequest -Value {
    $outFile = $args[[Array]::IndexOf([object[]]$args, '-OutFile') + 1]
    # PowerShell publishes hashes.sha256 as UTF-16 with a byte-order mark.
    Set-Content -LiteralPath $outFile -Encoding Unicode -Value "$('0' * 64) *PowerShell-7.6.10-win-arm64.msi`r`n$msiSum *PowerShell-7.6.10-win-x64.msi"
}
$savedArch = $env:PROCESSOR_ARCHITECTURE; $savedWow = $env:PROCESSOR_ARCHITEW6432
try {
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'; $env:PROCESSOR_ARCHITEW6432 = $null
    Assert-True ((Get-PowerShellLtsVersion) -eq '7.6.10') 'the newest stable LTS tag is selected (previews and older LTS ignored)'
    $script:RestUris = @()
    $release = Get-PowerShellLtsRelease
    Assert-True ($release.Version -eq '7.6.10' -and $release.Name -eq 'PowerShell-7.6.10-win-x64.msi' -and $release.Sha256 -eq $msiSum) 'LTS MSI and checksum resolved for x64'
    Assert-True ($script:RestUris -contains 'https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v7.6.10') 'the LTS release is looked up by its tag'
    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    $threw = $false
    try { Get-PowerShellLtsRelease | Out-Null } catch { $threw = $_.Exception.Message -match 'lacks exactly one PowerShell-7\.6\.10-win-arm64\.msi' }
    Assert-True $threw 'arm64 host selects the arm64 MSI (absent in this fixture)'
    $env:PROCESSOR_ARCHITEW6432 = $null
    $script:LtsTags = @('v7.8.0-preview.1')
    $threw = $false
    try { Get-PowerShellLtsVersion | Out-Null } catch { $threw = $_.Exception.Message -match 'no stable LTSReleaseTag' }
    Assert-True $threw 'metadata without a stable LTS tag is rejected'
}
finally {
    $env:PROCESSOR_ARCHITECTURE = $savedArch; $env:PROCESSOR_ARCHITEW6432 = $savedWow
    Remove-Item -Path function:Invoke-RestMethod, function:Invoke-WebRequest -ErrorAction SilentlyContinue
}
Assert-True ($scriptText.IndexOf('$pwshResult = Invoke-PowerShellMsiSwitch') -lt $scriptText.IndexOf('#--- 4. Self-updating native CLIs')) 'PowerShell switch runs in the package phase'
Assert-True ($scriptText -match "(?m)^if \(.*-or \`$pwshResult -eq 'failed'.*\) \{ exit 1 \}\r?$") 'a failed PowerShell switch fails the run'
Assert-True ($scriptText -match "(?m)^if \(.*-or \`$googetResult -eq 'failed'.*\) \{ exit 1 \}\r?$") 'a failed GooGet step fails the run'
Write-Output 'POWERSHELL MSI PASSED'

# --- game-packages GooGet packages -------------------------------------------
Assert-True (($GooGetPackages -join ',') -eq 'crossdock,carryout') 'core installs the jm2 tools without a WinGet package from game-packages'
Assert-True (($GooGetFullPackages -join ',') -eq 'bugdom,bugdom2,cro-mag-rally-net,mightymike,nanosaur,nanosaur2,ottomatic') 'full adds the Linux full-profile game set'
foreach ($id in @($WingetPackages) + @($WingetFullPackages)) {
    Assert-True ($id -notmatch '(?i)bugdom|nanosaur|ottomatic|mightymike|cromag|cro-mag|crossdock|carryout') "no second source for a game-packages package ($id)"
}
Assert-True ((@(Get-GooGetInstalledName -Lines @('Installed packages:', '  crossdock.x86_64 0.2.3@1', '  cro-mag-rally-net.arm64 3.2.0@2', '  bugdom.noarch 1.3.4@1', 'garbage')) -join ',') -eq 'crossdock,cro-mag-rally-net,bugdom') 'googet installed output is parsed to package names'

$script:GooRoot = Join-Path ([IO.Path]::GetTempPath()) ("goo-pkg-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$script:GooCalls = @(); $script:GooInstalled = @(); $script:GooReachable = $true; $script:GooInstallExit = 0; $script:GooInstallsAll = $true
$script:GooExe = Join-Path $script:GooRoot 'googet.exe'
function Get-GooGetRoot { $script:GooRoot }
function Get-GooGetInstall { if ($script:GooExe) { [pscustomobject]@{ Exe = $script:GooExe; Commit = 'c'; Version = '3.4.1'; Repo = 'jm2/googet' } } }
function Test-GooGetRepoReachable { $script:GooReachable }
function Invoke-GooGetCommand {
    param([string]$Exe, [string]$Root, [string[]]$Arguments)
    $script:GooCalls += "$Exe|-root|$Root|$($Arguments -join '|')"
    if ($Arguments[0] -eq 'installed') {
        'Installed packages:'
        foreach ($name in $script:GooInstalled) { "  $name.noarch 1.0.0@1" }
        $global:LASTEXITCODE = if ($script:GooInstalled.Count) { 0 } else { 1 }
        return
    }
    if ($script:GooInstallsAll) { $script:GooInstalled = @(@($script:GooInstalled) + @($Arguments | Select-Object -Skip 2) | Select-Object -Unique) }
    $global:LASTEXITCODE = $script:GooInstallExit
}
$set = @('crossdock', 'carryout', 'bugdom')
$installPrefix = "$script:GooExe|-root|$script:GooRoot|-noconfirm|install"

$r = Invoke-GooGetPackageSet -Packages $set 6>$null
Assert-True ((@($script:GooCalls | Where-Object { $_ -like '*|install|*' }) -join "`n") -eq "$installPrefix|crossdock|carryout|bugdom") 'nothing installed (googet installed exits 1): every package installs, non-interactively, with -root'
Assert-True (($r.Installed -join ',') -eq 'crossdock,carryout,bugdom' -and $r.Failed.Count -eq 0 -and $r.Deferred.Count -eq 0) 'fresh install reports every package installed'

$script:GooCalls = @(); $script:GooInstalled = @('crossdock', 'carryout')
$r = Invoke-GooGetPackageSet -Packages $set 6>$null
Assert-True ((@($script:GooCalls | Where-Object { $_ -like '*|install|*' }) -join "`n") -eq "$installPrefix|crossdock|carryout|bugdom") 'installed packages are passed to googet install too, which updates them to the latest'
Assert-True (($r.Installed -join ',') -eq 'bugdom' -and ($r.Current -join ',') -eq 'crossdock,carryout') 'only the missing package counts as installed now'

$script:GooCalls = @(); $script:GooInstalled = @('crossdock', 'carryout')
$r = Invoke-GooGetPackageSet -Packages $set -NoUpgrade 6>$null
Assert-True ((@($script:GooCalls | Where-Object { $_ -like '*|install|*' }) -join "`n") -eq "$installPrefix|bugdom") '-NoUpgrade installs only the missing package'
$script:GooCalls = @()
$r = Invoke-GooGetPackageSet -Packages $set -NoUpgrade 6>$null
Assert-True (@($script:GooCalls | Where-Object { $_ -like '*|install|*' }).Count -eq 0 -and ($r.Current -join ',') -eq 'crossdock,carryout,bugdom') '-NoUpgrade with everything present runs no install'

$script:GooCalls = @(); $script:GooReachable = $false
$r = Invoke-GooGetPackageSet -Packages $set 6>$null
Assert-True ($script:GooCalls.Count -eq 0 -and ($r.Deferred -join ',') -eq 'crossdock,carryout,bugdom' -and $r.Failed.Count -eq 0) 'an unreachable enthoo defers every package without calling googet'
$script:GooReachable = $true

$savedExe = $script:GooExe; $script:GooExe = $null
$r = Invoke-GooGetPackageSet -Packages $set 6>$null
Assert-True (($r.Deferred -join ',') -eq 'crossdock,carryout,bugdom' -and $r.Failed.Count -eq 0) 'packages wait for googet to be built'
$script:GooExe = $savedExe

$script:GooInstalled = @('crossdock'); $script:GooInstallsAll = $false; $script:GooInstallExit = 1
$r = Invoke-GooGetPackageSet -Packages $set 6>$null 3>$null
Assert-True (($r.Failed -join ',') -eq 'carryout,bugdom' -and ($r.Current -join ',') -eq 'crossdock' -and $r.Installed.Count -eq 0) 'a failed googet install reports the packages still missing'
$script:GooInstalled = @('crossdock', 'carryout', 'bugdom')
$r = Invoke-GooGetPackageSet -Packages $set 6>$null 3>$null
Assert-True (($r.Failed -join ',') -eq 'crossdock,carryout,bugdom') 'a non-zero googet install exit with nothing missing is still a failure'
$script:GooInstallsAll = $true; $script:GooInstallExit = 0

function Invoke-GooGetCommand { param([string]$Exe, [string]$Root, [string[]]$Arguments) $script:GooCalls += "$Exe|$Root|$($Arguments -join '|')"; 'Error: database is locked'; $global:LASTEXITCODE = 1 }
$r = Invoke-GooGetPackageSet -Packages $set 6>$null 3>$null
Assert-True (($r.Failed -join ',') -eq 'crossdock,carryout,bugdom') 'a failing googet installed query fails the set'
foreach ($name in @('Get-GooGetRoot', 'Get-GooGetInstall', 'Test-GooGetRepoReachable', 'Invoke-GooGetCommand')) {
    Remove-Item -Path "function:$name" -ErrorAction SilentlyContinue
}
# The probe reads the index googet itself uses: index.gz, then index.
. ([scriptblock]::Create($ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-GooGetRepoReachable' }, $true).Extent.Text))
$script:ProbeUrls = @(); $script:ProbeOk = @()
Set-Item -Path function:Invoke-WebRequest -Value {
    param([string]$Uri, [switch]$UseBasicParsing, [int]$TimeoutSec)
    if (-not $UseBasicParsing) { throw 'the probe must use basic parsing (no IE engine on Server Core)' }
    $script:ProbeUrls += "$Uri|$TimeoutSec"
    if ($script:ProbeOk -notcontains $Uri) { throw 'unreachable' }
}
Assert-True (-not (Test-GooGetRepoReachable)) 'an unreachable repo fails the probe'
Assert-True (($script:ProbeUrls -join ',') -eq "$GooGetRepoUrl/index.gz|5,$GooGetRepoUrl/index|5") 'the probe tries index.gz then index with a short timeout'
$script:ProbeOk = @("$GooGetRepoUrl/index")
Assert-True (Test-GooGetRepoReachable) 'an uncompressed index counts as reachable'
Remove-Item -Path function:Invoke-WebRequest, function:Test-GooGetRepoReachable -ErrorAction SilentlyContinue
Write-Output 'GAME-PACKAGES GOOGET PASSED'

Write-Output 'ALL WIN11 PROFILE ASSERTIONS PASSED'
