param(
    [string]$ScriptPath = (Join-Path (Join-Path $PSScriptRoot '..') 'setup-win11-workstation.ps1')
)

$ErrorActionPreference = 'Stop'

# Load only the OpenCode purge declarations and helpers; registry and process
# access are replaced with in-memory fakes below.
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

foreach ($assignmentName in @('OpenCodeRcFiles', 'OpenCodeUninstallWaitSeconds')) {
    $assignmentAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq $assignmentName
    }, $true)
    if (-not $assignmentAst) { throw "$assignmentName declaration not found" }
    . ([scriptblock]::Create($assignmentAst.Extent.Text))
}

foreach ($functionName in @('Get-OpenCodeNativeBin', 'Get-PathListWithout', 'Get-OpenCodeRcCleanText',
        'Split-UninstallCommand', 'Get-OpenCodeRcPath', 'Get-OpenCodeNativeLeftover', 'Invoke-OpenCodeNativePurge')) {
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

# PATH filtering: case-insensitive, trailing slash and %VAR% tolerant, and
# every other entry kept verbatim.
$savedProfile = $env:USERPROFILE
$root = Join-Path ([IO.Path]::GetTempPath()) ("opencode-purge-test-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    $env:USERPROFILE = Join-Path $root 'profile'
    $bin = Get-OpenCodeNativeBin
    Assert-Equal $bin (Join-Path (Join-Path $env:USERPROFILE '.opencode') 'bin') 'native OpenCode CLI directory'
    $kept = Get-PathListWithout -Entries @('%USERPROFILE%\.local\bin', '%USERPROFILE%\.opencode\bin', ($bin.ToUpperInvariant() + '\'), 'C:\Tools') -Directory $bin
    Assert-Equal ($kept -join ';') '%USERPROFILE%\.local\bin;C:\Tools' 'only OpenCode PATH entries are dropped, others stay unexpanded'
    Assert-Equal (Get-PathListWithout -Directory $bin).Count 0 'an empty PATH stays empty'

    # rc stripping removes exactly the installer's three-line block.
    $lf = "export EDITOR=vim`n`n# opencode`nexport PATH=/c/Users/me/.opencode/bin:`$PATH`nalias ll='ls -l'`n"
    Assert-Equal (Get-OpenCodeRcCleanText -Text $lf) "export EDITOR=vim`nalias ll='ls -l'`n" 'LF rc block removed'
    $crlf = "a`r`n`r`n# opencode`r`nexport PATH=/home/me/.opencode/bin:`$PATH`r`nb`r`n"
    Assert-Equal (Get-OpenCodeRcCleanText -Text $crlf) "a`r`nb`r`n" 'CRLF rc block removed with endings kept'
    $unrelated = "# opencode`nexport PATH=/c/Users/me/bin:`$PATH`nexport PATH=/c/Users/me/.opencode/bin:`$PATH`n"
    Assert-Equal (Get-OpenCodeRcCleanText -Text $unrelated) $unrelated 'PATH lines without the installer comment are kept'
    Assert-Equal (Get-OpenCodeRcCleanText -Text '') '' 'empty rc text'

    # Uninstall command parsing.
    $quoted = Split-UninstallCommand -Command '"C:\Users\me\AppData\Local\OpenCode\uninstall.exe" /S'
    Assert-Equal "$($quoted.FilePath)|$($quoted.Arguments)" 'C:\Users\me\AppData\Local\OpenCode\uninstall.exe|/S' 'quoted uninstaller'
    $bare = Split-UninstallCommand -Command 'C:\Program Files\OpenCode\uninstall.exe /S /D=x'
    Assert-Equal "$($bare.FilePath)|$($bare.Arguments)" 'C:\Program Files\OpenCode\uninstall.exe|/S /D=x' 'unquoted uninstaller with a space'
    $noArgs = Split-UninstallCommand -Command '"C:\x\uninstall.exe"'
    Assert-Equal "$($noArgs.FilePath)|$($noArgs.Arguments)" 'C:\x\uninstall.exe|' 'uninstaller without arguments'
    $rejected = $false
    try { Split-UninstallCommand -Command 'msiexec' | Out-Null } catch { $rejected = $_.Exception.Message -like 'unrecognized uninstall command*' }
    Assert-Equal $rejected $true 'unparseable uninstall command is rejected'

    # Fakes for the registry-backed pieces.
    $script:UserPath = @('%USERPROFILE%\.local\bin', $bin)
    function Get-UserPathEntry { return @($script:UserPath) }
    function Remove-UserPathEntry {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param([string]$Directory)
        if (-not $PSCmdlet.ShouldProcess('user PATH', "remove $Directory")) { return $false }
        $keptEntries = Get-PathListWithout -Entries $script:UserPath -Directory $Directory
        if ($keptEntries.Count -eq $script:UserPath.Count) { return $false }
        $script:UserPath = $keptEntries
        return $true
    }
    $script:Entries = @(
        [pscustomobject]@{ DisplayName = 'OpenCode'; Key = 'HKCU:\u\OpenCode'; QuietUninstallString = ''; UninstallString = '"C:\oc\uninstall.exe"' }
        [pscustomobject]@{ DisplayName = 'OpenCode Desktop'; Key = 'HKLM:\u\OCD'; QuietUninstallString = '"C:\ocd\uninstall.exe" /S /quiet'; UninstallString = '"C:\ocd\uninstall.exe"' }
    )
    function Get-OpenCodeUninstallEntry { return $script:Entries }
    $script:Uninstalls = @()
    $script:UninstallExit = 0
    # Uninstaller path -> the uninstall key a successful run deletes.
    $script:UninstallerKeys = @{ 'C:\oc\uninstall.exe' = 'HKCU:\u\OpenCode'; 'C:\ocd\uninstall.exe' = 'HKLM:\u\OCD' }
    function Invoke-UninstallCommand {
        param([string]$FilePath, [string]$Arguments)
        $script:Uninstalls += "$FilePath|$Arguments"
        if ($script:UninstallExit -eq 0) {
            $script:Entries = @($script:Entries | Where-Object { $_.Key -ne $script:UninstallerKeys[$FilePath] })
        }
        return $script:UninstallExit
    }

    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $env:USERPROFILE '.config\opencode') | Out-Null
    foreach ($name in @('opencode.exe', 'opencode2.exe', 'opencode2.cmd')) { Set-Content -LiteralPath (Join-Path $bin $name) -Value 'x' }
    Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.config\opencode\opencode.json') -Value '{}'
    $bashrc = Join-Path $env:USERPROFILE '.bashrc'
    [IO.File]::WriteAllText($bashrc, $lf)
    $profileRc = Join-Path $env:USERPROFILE '.profile'
    [IO.File]::WriteAllText($profileRc, "export LANG=C`n")

    $leftovers = Get-OpenCodeNativeLeftover
    Assert-Equal $leftovers.Count 5 'check reports the CLI, PATH entry, rc lines and both desktop entries'

    $result = Invoke-OpenCodeNativePurge 3>$null
    Assert-Equal $result.Failed.Count 0 'purge has no failures'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.opencode')) $false 'native CLI directory and its empty parent are removed'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')) $true 'OpenCode config stays'
    Assert-Equal ($script:UserPath -join ';') '%USERPROFILE%\.local\bin' 'OpenCode user PATH entry removed'
    Assert-Equal ([IO.File]::ReadAllText($bashrc)) "export EDITOR=vim`nalias ll='ls -l'`n" '.bashrc cleaned'
    Assert-Equal ([IO.File]::ReadAllText($profileRc)) "export LANG=C`n" 'unrelated rc file untouched'
    Assert-Equal ($script:Uninstalls -join ',') 'C:\oc\uninstall.exe|/S,C:\ocd\uninstall.exe|/S /quiet' 'quiet uninstall string preferred, else /S appended'
    Assert-Equal $result.Removed.Count 5 'every removal is reported'

    $script:Uninstalls = @()
    $result = Invoke-OpenCodeNativePurge
    Assert-Equal "$($result.Removed.Count)/$($result.Failed.Count)/$($script:Uninstalls.Count)" '0/0/0' 'a second purge is a no-op'
    Assert-Equal (Get-OpenCodeNativeLeftover).Count 0 'check is clean after the purge'

    # A failing or ineffective uninstaller is reported, not hidden.
    $script:Entries = @([pscustomobject]@{ DisplayName = 'OpenCode'; Key = 'HKCU:\u\Stuck'; QuietUninstallString = '"C:\stuck\uninstall.exe" /S'; UninstallString = '' })
    $script:UninstallExit = 2
    $result = Invoke-OpenCodeNativePurge 3>$null
    Assert-Equal ($result.Failed -join ',') 'uninstall OpenCode' 'non-zero uninstaller exit is a failure'
    $script:UninstallExit = 0
    $script:OpenCodeUninstallWaitSeconds = 0
    $result = Invoke-OpenCodeNativePurge 3>$null
    Assert-Equal ($result.Failed -join ',') 'uninstall OpenCode' 'an uninstall entry that survives the uninstaller is a failure'

    # NSIS uninstallers return before their relaunched copy removes the entry.
    $script:OpenCodeUninstallWaitSeconds = 30
    $script:Entries = @([pscustomobject]@{ DisplayName = 'OpenCode'; Key = 'HKCU:\u\Late'; QuietUninstallString = '"C:\late\uninstall.exe" /S'; UninstallString = '' })
    $script:EntryReads = 0
    function Get-OpenCodeUninstallEntry {
        $script:EntryReads++
        if ($script:EntryReads -gt 2) { return @() }
        return $script:Entries
    }
    function Invoke-UninstallCommand { param([string]$FilePath, [string]$Arguments) $script:Uninstalls += "$FilePath|$Arguments"; return 0 }
    $result = Invoke-OpenCodeNativePurge 3>$null
    Assert-Equal "$($result.Failed.Count)/$($result.Removed -join ',')" '0/OpenCode desktop app' 'an entry removed shortly after the uninstaller exits counts as success'
}
finally {
    $env:USERPROFILE = $savedProfile
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'ALL OPENCODE PURGE ASSERTIONS PASSED'
