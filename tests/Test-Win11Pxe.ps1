#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $repo 'win11pxe/BuildHelpers.psm1') -Force -PassThru
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "win11pxe-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null

function Assert-Pxe {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}
function Assert-PxeFailure {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-Pxe ($null -ne $caught -and $caught.Exception.Message -like $Pattern) "Expected failure matching $Pattern; got $caught"
}

try {
    $guid = 'ce5d2b7f-9d81-4a14-92c8-25afc8e0a110'
    $adapter = [pscustomobject]@{ GUID = "{$guid}"; Name = 'NIC'; ServiceName = 'testnic'; PNPDeviceID = 'PCI\VEN_1234'; ConfigManagerErrorCode = 0 }
    Assert-Pxe (@(Resolve-PxeBootAdapter @($guid, "{$guid}") @($adapter)).Count -eq 1) 'GUID normalization/deduplication'
    Assert-PxeFailure { Resolve-PxeBootAdapter @('-' * 36) @($adapter) } '*Invalid*GUID*'
    Assert-PxeFailure { Resolve-PxeBootAdapter @([guid]::Empty.ToString()) @($adapter) } '*Invalid*GUID*'
    Assert-PxeFailure { Resolve-PxeBootAdapter @([guid]::NewGuid().ToString()) @($adapter) } '*must be present*'
    $adapter.ConfigManagerErrorCode = 22
    Assert-PxeFailure { Resolve-PxeBootAdapter @($guid) @($adapter) } '*working driver*'
    $adapter.ConfigManagerErrorCode = 0
    $adapter.ServiceName = ''
    Assert-PxeFailure { Resolve-PxeBootAdapter @($guid) @($adapter) } '*working driver*'
    Assert-Pxe (@(Resolve-PxeBootAdapter @() @()).Count -eq 0) 'GUID-less builds permitted'

    $driverDir = New-Item -ItemType Directory (Join-Path $scratch 'driver [tested]')
    $inf = Join-Path $driverDir.FullName 'test.inf'
    Set-Content -LiteralPath $inf -Value '[Version]'
    Assert-Pxe ((Resolve-PxeDriverPath @($inf)) -eq $inf) 'Literal INF path with brackets'
    Assert-Pxe ((Resolve-PxeDriverPath @($driverDir.FullName)) -eq $driverDir.FullName) 'Extracted driver directory'
    Assert-PxeFailure { Resolve-PxeDriverPath @(Join-Path $scratch 'missing') } '*does not exist*'
    $emptyDir = New-Item -ItemType Directory (Join-Path $scratch 'empty')
    Assert-PxeFailure { Resolve-PxeDriverPath @($emptyDir.FullName) } '*no INF*'
    $first = Join-Path $driverDir.FullName 'test.sys'
    $second = Join-Path $emptyDir.FullName 'test.sys'
    Set-Content -LiteralPath $first -Value 'same binary'
    Copy-Item -LiteralPath $first -Destination $second
    $candidates = @(Get-Item -LiteralPath $first, $second)
    Assert-Pxe ($null -ne (Select-PxeDriverBinary $candidates)) 'Identical driver copies accepted'
    Set-Content -LiteralPath $second -Value 'different binary'
    Assert-PxeFailure { Select-PxeDriverBinary $candidates } '*Ambiguous boot driver*'
    Assert-PxeFailure { Resolve-PxeDriverPath @($first) } '*must be an INF*'

    $fakeDism = Join-Path $scratch 'fake-dism.ps1'
    $report = @{ DismOperations = [System.Collections.Generic.List[object]]::new() }
    foreach ($code in 0, 3010) {
        Set-Content $fakeDism "exit $code"
        Invoke-PxeDism -Executable $fakeDism -Report $report -Arguments @('/Add-NetAdapter', '/HostAdapter:{test}')
        Assert-Pxe ($report.DismOperations[-1].ExitCode -eq $code) 'Successful DISM exit recorded'
    }
    Set-Content $fakeDism 'exit 87'
    Assert-PxeFailure { Invoke-PxeDism -Executable $fakeDism -Report $report -Arguments @('/Add-NetAdapter') } '*failed (exit 87)*'
    Assert-Pxe ($report.DismOperations[-1].ExitCode -eq 87) 'Failed DISM exit retained'

    $output = Join-Path $scratch 'windows.vhdx'
    $working = Join-Path $scratch 'new.vhdx'
    $reportPath = Join-Path $scratch 'build.json'
    Set-Content $output 'previous image'
    Set-Content $working 'new image'
    $report = @{ State = 'Building'; Warnings = @(); ColdBootValidated = $false }
    Assert-PxeFailure { Publish-PxeImage $working $output $reportPath $report } '*cleanup must succeed*'
    Assert-Pxe ((Get-Content $output) -eq 'previous image') 'Unfinished build preserves output'
    $report.State = 'ReadyToPublish'
    Assert-PxeFailure { Publish-PxeImage $working $output (Join-Path $scratch 'missing/report.json') $report } '*'
    Assert-Pxe ((Get-Content $output) -eq 'previous image') 'Report-write failure preserves output'
    Publish-PxeImage $working $output $reportPath $report
    Assert-Pxe ((Get-Content $output) -eq 'new image') 'Successful replacement'
    Assert-Pxe (-not (Test-Path $working)) 'Successful build consumes temporary file'
    Assert-Pxe ((Get-Content -Raw $reportPath | ConvertFrom-Json).State -eq 'Complete') 'Completion report saved'

    # Fault injection after the image swap proves publication rollback, not just preflight.
    & $module {
        $script:originalReportWriter = ${function:Write-PxeBuildReport}
        $script:reportWrites = 0
        function script:Write-PxeBuildReport {
            param($Report, $Path)
            $script:reportWrites++
            if ($script:reportWrites -eq 2) { throw 'injected completion report failure' }
            & $script:originalReportWriter $Report $Path
        }
    }
    Set-Content $working 'replacement that must roll back'
    $report.State = 'ReadyToPublish'
    Assert-PxeFailure { Publish-PxeImage $working $output $reportPath $report } '*injected completion*'
    Assert-Pxe ((Get-Content $output) -eq 'new image') 'Completion report failure rolls back previous image'
    Assert-Pxe ((Get-Content $working) -eq 'replacement that must roll back') 'Failed replacement retained'
    & $module { Set-Item Function:Write-PxeBuildReport $script:originalReportWriter }

    Remove-Item $output
    $report.State = 'ReadyToPublish'
    Publish-PxeImage $working $output $reportPath $report
    Assert-Pxe (Test-Path $output) 'First publication without previous image'

    # Execute the builder's actual finally block with mocked Windows operations.
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'build_win11pxe.ps1'), [ref]$tokens, [ref]$parseErrors)
    Assert-Pxe ($parseErrors.Count -eq 0) 'Builder parses'
    $mainTry = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -First 1
    $cleanupText = $mainTry.Finally.Extent.Text
    $cleanup = [scriptblock]::Create($cleanupText.Substring(1, $cleanupText.Length - 2))
    function Invoke-CleanupCase {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are consumed by the actual builder finally block executed below.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Mock Windows operations while executing the actual cleanup block.')]
        param([string]$Case)
        $state = @{ Loaded = $true; Attached = $true; Detaches = 0; IsoCalls = 0 }
        $success = $true; $vhdCreated = $true; $sysHiveLoaded = $true; $softHiveLoaded = $false
        $tempHiveName = 'test-system'; $tempSoftName = $null; $workingPath = 'test.vhdx'
        $isoImage = $true; $IsoPath = 'test.iso'
        $dismScratchDir = $null; $driverTempPath = $null; $updatesTempPath = $null
        $report = @{ Warnings = [System.Collections.Generic.List[string]]::new() }
        function Dismount-Hive {
            param($HiveName)
            Assert-Pxe ($HiveName -eq 'test-system') 'Correct hive targeted'
            if ($Case -eq 'hive-throws') { throw 'hive failure' }
            if ($Case -eq 'hive-fails') { return $false }
            $state.Loaded = $false
            return $true
        }
        function Test-Path {
            param($Path)
            Assert-Pxe ($Path -eq 'HKLM:\test-system') 'Cleanup only probes tracked hive'
            $state.Loaded
        }
        function Dismount-DiskImage {
            [CmdletBinding()]param($ImagePath)
            Assert-Pxe ($ImagePath -eq 'test.iso') 'Correct ISO targeted'
            $state.IsoCalls++
            if ($Case -eq 'iso-fails') { throw 'ISO failure' }
        }
        function Get-VHD {
            [CmdletBinding()]param($Path)
            Assert-Pxe ($Path -eq 'test.vhdx') 'Only temporary VHD queried'
            [pscustomobject]@{ Attached = $state.Attached }
        }
        function Dismount-VHD {
            [CmdletBinding()]param($Path)
            Assert-Pxe ($Path -eq 'test.vhdx') 'Only temporary VHD detached'
            $state.Detaches++
            if ($Case -eq 'detach-fails') { throw 'detach failure' }
            if ($Case -ne 'still-attached') { $state.Attached = $false }
        }
        . $cleanup
        Assert-Pxe ($state.IsoCalls -eq 1) "$Case still attempts independent ISO cleanup"
        if ($Case -like 'hive-*') { Assert-Pxe ($state.Detaches -eq 0) "$Case never detaches with loaded hive" }
        Assert-Pxe ($success -eq ($Case -eq 'ok')) "$Case publication eligibility"
    }
    foreach ($case in 'ok', 'hive-fails', 'hive-throws', 'iso-fails', 'detach-fails', 'still-attached') {
        Invoke-CleanupCase $case
    }

    if ($IsWindows) {
        $registry = "HKCU:\Software\Win11PxeTest-$([guid]::NewGuid().ToString('N'))"
        $servicePath = "$registry\ControlSet001\Services\testnic"
        try {
            New-Item "$servicePath\StartOverride" -Force | Out-Null
            Set-ItemProperty $servicePath -Name Start -Value 0 -Type DWord
            Set-ItemProperty $servicePath -Name ImagePath -Value 'System32\drivers\test.sys' -Type ExpandString
            Set-ItemProperty "$servicePath\StartOverride" -Name '0' -Value 3 -Type DWord
            New-Item -ItemType Directory (Join-Path $scratch 'System32\drivers') -Force | Out-Null
            Copy-Item -LiteralPath $first -Destination (Join-Path $scratch 'System32\drivers\test.sys')
            $audit = Get-PxeServiceAudit $registry $scratch ControlSet001 testnic
            Assert-Pxe ($audit.BinaryExists -and $audit.Start -eq 0 -and $audit.BootFlags -eq 0) 'Native registry audit handles absent BootFlags'
            Assert-Pxe ($audit.StartOverride['0'] -eq 3) 'Native registry audit records overrides'
        }
        finally { Remove-Item $registry -Recurse -Force }
    }
    Write-Output 'Win11 PXE build regression tests: PASS'
}
finally {
    Remove-Module $module -Force
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
