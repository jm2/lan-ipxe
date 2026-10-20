param(
    [string]$ScriptPath = (Join-Path (Join-Path $PSScriptRoot '..') 'enable-openssh-win11.ps1')
)

$ErrorActionPreference = 'Stop'

# Load the helper's declarations and functions only: the script itself
# #Requires elevation and drives live Windows services.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $ScriptPath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Script has parser errors: $($parseErrors -join '; ')" }
$tokens.Count | Out-Null
foreach ($node in $ast.FindAll({
            param($candidate)
            ($candidate -is [System.Management.Automation.Language.FunctionDefinitionAst]) -or
            ($candidate -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $candidate.Parent -eq $ast.EndBlock -and
                $candidate.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $candidate.Left.VariablePath.UserPath -in @('CapabilityName', 'OpenSshRegKey', 'DesiredShell'))
        }, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "ASSERT: $Message (actual=[$Actual], expected=[$Expected])"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("openssh-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$savedSystemRoot = $env:SystemRoot
try {
    $env:SystemRoot = $root
    $inbox = Join-Path $root 'System32\OpenSSH\sshd.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $inbox) | Out-Null
    Set-Content -LiteralPath $inbox -Value 'sshd'

    # Inbox service detection: the registered ImagePath must be the inbox
    # binary (quoted, %SystemRoot%-relative or literal), and it must exist.
    $script:ImagePath = $null
    Set-Item -Path function:Get-ItemProperty -Value {
        param([string]$Path, [string]$Name)
        if ($Path -like '*\Services\sshd' -and $Name -eq 'ImagePath' -and $script:ImagePath) {
            return [pscustomobject]@{ ImagePath = $script:ImagePath }
        }
        if ($Path -eq $OpenSshRegKey -and $Name -eq 'DefaultShell' -and $script:Shell) {
            return [pscustomobject]@{ DefaultShell = $script:Shell }
        }
    }
    Assert-Equal (Test-InboxSshdService) $false 'no sshd service registration means DISM must be asked'
    $script:ImagePath = '%SystemRoot%\System32\OpenSSH\sshd.exe'
    Assert-Equal (Test-InboxSshdService) $true 'a %SystemRoot%-relative inbox registration counts'
    $script:ImagePath = "`"$inbox`""
    Assert-Equal (Test-InboxSshdService) $true 'a quoted inbox registration counts'
    $script:ImagePath = 'C:\Program Files\OpenSSH\sshd.exe'
    Assert-Equal (Test-InboxSshdService) $false 'a Win32-OpenSSH MSI service does not prove the capability'
    $script:ImagePath = $inbox
    Remove-Item -LiteralPath $inbox
    Assert-Equal (Test-InboxSshdService) $false 'a registration whose inbox binary is gone does not count'
    Set-Content -LiteralPath $inbox -Value 'sshd'

    # The DISM cmdlets run in-process when they can; "Class not registered"
    # (PowerShell 7, WOW64, emulated hosts) falls back to native Windows
    # PowerShell, which must not be reached when the cmdlet works.
    $script:CmdletFails = $false
    $script:Added = 0
    function Get-WindowsCapability {
        if ($script:CmdletFails) { throw 'Class not registered' }
        [pscustomobject]@{ State = 'NotPresent' }
    }
    function Add-WindowsCapability {
        if ($script:CmdletFails) { throw 'Class not registered' }
        $script:Added++
    }
    $hostPath = Get-NativeWindowsPowerShell
    Assert-Equal ($hostPath -like (Join-Path $root '*\WindowsPowerShell\v1.0\powershell.exe')) $true 'native Windows PowerShell is resolved under %SystemRoot%'
    Assert-Equal (Invoke-CapabilityCommand -Verb Get) 'NotPresent' 'in-process capability query'
    Assert-Equal (Invoke-CapabilityCommand -Verb Add) 'Installed' 'in-process capability install'
    Assert-Equal $script:Added 1 'Add-WindowsCapability ran once in-process'

    $script:CmdletFails = $true
    $rejected = $false
    try { Invoke-CapabilityCommand -Verb Get | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*Class not registered*Windows PowerShell was not found*' }
    Assert-Equal $rejected $true 'a failed cmdlet without a Windows PowerShell host reports both problems'

    # A stand-in native host: prints the requested capability state.
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $hostPath) | Out-Null
    Set-Content -LiteralPath $hostPath -Value ''
    $script:HostCalls = @()
    $script:HostExit = 0
    Set-Item -Path "function:global:$hostPath" -Value {
        $script:HostCalls += ($args -join ' ')
        $global:LASTEXITCODE = $script:HostExit
        if ($script:HostExit) { return 'Get-WindowsCapability : access denied' }
        if (($args -join ' ') -match 'Add-WindowsCapability') { return 'Installed' }
        return 'Installed'
    }
    Assert-Equal (Invoke-CapabilityCommand -Verb Get) 'Installed' 'capability query falls back to native Windows PowerShell'
    Assert-Equal ($script:HostCalls[0] -match "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command .*Get-WindowsCapability -Online -Name '$([regex]::Escape($CapabilityName))'") $true 'fallback runs the same query non-interactively'
    Assert-Equal (Invoke-CapabilityCommand -Verb Add) 'Installed' 'capability install falls back to native Windows PowerShell'
    Assert-Equal ($script:HostCalls[1] -match 'Add-WindowsCapability -Online') $true 'fallback runs the install'
    $script:HostExit = 1
    $rejected = $false
    try { Invoke-CapabilityCommand -Verb Get | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*failed in-process (Class not registered) and in Windows PowerShell: *access denied*' }
    Assert-Equal $rejected $true 'a failing fallback reports both errors'
    Remove-Item -Path "function:global:$hostPath"

    # The read-only probe never touches DISM.
    $script:CmdletFails = $false
    function Get-WindowsCapability { throw 'the probe must not query DISM' }
    Set-Item -Path function:Get-Service -Value { [pscustomobject]@{ StartType = 'Automatic'; Status = 'Running' } }
    function Get-SshFirewallRule { @([pscustomobject]@{ Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any' }) }
    function Get-NetFirewallPortFilter { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '22' } }
    $script:Shell = $DesiredShell
    $probe = { (Test-InboxSshdService) -and (Test-SshdServiceState) -and (Test-SshFirewallRule -Rules (Get-SshFirewallRule)) -and ((Get-SshDefaultShell) -eq $DesiredShell) }
    Assert-Equal (& $probe) $true 'a converged machine passes the probe'
    $script:Shell = 'C:\Windows\System32\cmd.exe'
    Assert-Equal (& $probe) $false 'a different DefaultShell fails the probe'
    $script:Shell = $DesiredShell
    function Get-NetFirewallPortFilter { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '2222' } }
    Assert-Equal (& $probe) $false 'a firewall rule for the wrong port fails the probe'
    $scriptText = Get-Content -Raw -LiteralPath $ScriptPath
    Assert-Equal ($scriptText -match '(?s)if \(\$Test\) \{\s*return \(Test-InboxSshdService\) -and \(Test-SshdServiceState\) -and\s*\(Test-SshFirewallRule -Rules \(Get-SshFirewallRule\)\) -and\s*\(\(Get-SshDefaultShell\) -eq \$DesiredShell\)') $true 'the -Test probe is exactly the checks exercised above'
}
finally {
    $env:SystemRoot = $savedSystemRoot
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# setup-win11-workstation.ps1 -Check carries its own copy (it cannot run the
# elevated helper); keep the two identical.
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $ScriptPath) 'setup-win11-workstation.ps1')), [ref]$null, [ref]$null)
$bodies = foreach ($tree in @($ast, $setupAst)) {
    $tree.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-InboxSshdService' }, $true).Body.Extent.Text
}
Assert-Equal $bodies[1] $bodies[0] 'setup -Check uses the same inbox sshd test as the helper'

Write-Output 'ALL OPENSSH ASSERTIONS PASSED'
