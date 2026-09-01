$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -ErrorAction Stop
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $repoRoot
try {
    $files = @(
        & git ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' '*.psd1' |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    )
    if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) {
        throw 'No PowerShell files discovered through git ls-files'
    }
    Write-Output "Discovered $($files.Count) PowerShell/data files:"
    $files | ForEach-Object { Write-Output "  $_" }

    $parseFailures = @()
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path -LiteralPath $file),
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        foreach ($parseError in @($errors)) {
            $parseFailures += [pscustomobject]@{
                File = $file
                Line = $parseError.Extent.StartLineNumber
                Message = $parseError.Message
            }
        }
    }
    if ($parseFailures.Count) {
        $parseFailures | Format-Table -AutoSize
        throw "PowerShell parser found $($parseFailures.Count) error(s)"
    }
    Write-Output 'PowerShell parser: PASS'

    $issues = @($files | ForEach-Object {
        Invoke-ScriptAnalyzer -Path $_ -Severity Error,Warning
    })
    $issues | Format-Table -AutoSize
    $analyzerErrors = @($issues | Where-Object Severity -eq 'Error')
    if ($analyzerErrors.Count) {
        throw "PSScriptAnalyzer found $($analyzerErrors.Count) error(s)"
    }
    $analyzerWarnings = @($issues | Where-Object Severity -eq 'Warning')
    # The repository predates this check and has a finite body of visible
    # warning debt. These upper bounds let that debt shrink while making any
    # new warning class, affected file, or count increase fail CI.
    $warningAllowances = @{
        'setup-win11-workstation.ps1|PSAvoidUsingWriteHost' = 2
        'Get-Win11CumulativeUpdates.ps1|PSAvoidUsingWriteHost' = 23
        'build_win11pxe.ps1|PSAvoidUsingWriteHost' = 68
        'CatalogScrape.psm1|PSAvoidUsingWriteHost' = 20
        'Start-WreckfestLan.ps1|PSAvoidUsingWriteHost' = 2
        'Get-AmdGraphicsDrivers.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'Get-IntelGraphicsDrivers.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'Get-IntelWiFiDrivers.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'Get-MediatekWiFiDrivers.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'Get-NvidiaGraphicsDrivers.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'Get-QualcommWiFiDrivers.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'Get-Win11CumulativeUpdates.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'build_win11pxe.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'CatalogScrape.psm1|PSUseBOMForUnicodeEncodedFile' = 1
        'Test-CatalogScrape.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'amd-gfx.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'broadcom.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'intel-eth.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'intel-gfx.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'intel-wifi.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'marvell.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'mediatek.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'nvidia-gfx.psd1|PSUseBOMForUnicodeEncodedFile' = 1
        'Start-WreckfestLan.ps1|PSUseBOMForUnicodeEncodedFile' = 1
        'build_win11pxe.ps1|PSUseUsingScopeModifierInNewRunspaces' = 6
        'CatalogScrape.psm1|PSReviewUnusedParameter' = 1
        'CatalogScrape.psm1|PSUseSingularNouns' = 1
        'Get-Win11CumulativeUpdates.ps1|PSUseSingularNouns' = 1
        'Start-WreckfestLan.ps1|PSAvoidUsingEmptyCatchBlock' = 1
        'Start-WreckfestLan.ps1|PSUseShouldProcessForStateChangingFunctions' = 1
        'Test-HyperV.ps1|PSAvoidOverwritingBuiltInCmdlets' = 1
        'Test-HyperV.ps1|PSReviewUnusedParameter' = 8
    }
    $unexpectedWarnings = @()
    foreach ($group in @($analyzerWarnings | Group-Object { "$($_.ScriptName)|$($_.RuleName)" })) {
        $exactKey = [string]$group.Name
        if ($warningAllowances.ContainsKey($exactKey)) {
            $limit = $warningAllowances[$exactKey]
        }
        else {
            $limit = 0
        }
        if ($group.Count -gt $limit) {
            $unexpectedWarnings += $group.Group
        }
    }
    if ($unexpectedWarnings.Count) {
        $unexpectedWarnings | Format-Table -AutoSize
        throw "PSScriptAnalyzer found $($unexpectedWarnings.Count) warning(s) beyond the checked baseline"
    }
    Write-Output "PSScriptAnalyzer: PASS ($($analyzerWarnings.Count) allowed warning(s) reported; no baseline growth)"

    foreach ($dataFile in @($files | Where-Object { $_ -like '*.psd1' })) {
        Import-PowerShellDataFile -LiteralPath $dataFile | Out-Null
    }
    Write-Output 'PowerShell data files: PASS'

    $compatibilitySettings = @{
        Rules = @{
            PSUseCompatibleSyntax = @{
                Enable = $true
                TargetVersions = @('5.1')
            }
        }
    }
    $windows51Files = @(
        'setup-win11-workstation.ps1'
        'enable-openssh-win11.ps1'
        'enable-hyperv-win11.ps1'
    )
    $compatibilityIssues = @($windows51Files | ForEach-Object {
        Invoke-ScriptAnalyzer -Path $_ -Settings $compatibilitySettings -IncludeRule PSUseCompatibleSyntax
    })
    if ($compatibilityIssues.Count) {
        $compatibilityIssues | Format-Table -AutoSize
        throw 'Windows workstation scripts use syntax unavailable in PowerShell 5.1'
    }
    Write-Output 'Windows PowerShell 5.1 syntax compatibility: PASS'
}
finally {
    Pop-Location
}
