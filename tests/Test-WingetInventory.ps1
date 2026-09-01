param(
    [string]$ScriptPath = (Join-Path (Join-Path $PSScriptRoot '..') 'setup-win11-workstation.ps1')
)

$ErrorActionPreference = 'Stop'

# Load only Get-WingetInventory from the script AST. This avoids evaluating
# #Requires or any Windows-only setup code on the Linux CI runner.
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
$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-WingetInventory'
}, $true)
if (-not $functionAst) { throw 'Get-WingetInventory function not found' }
$functionDefinition = [scriptblock]::Create($functionAst.Extent.Text)
. $functionDefinition

$constantAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'WingetExportOkCodes'
}, $true)
if (-not $constantAst) { throw 'WingetExportOkCodes declaration not found' }
$constantDefinition = [scriptblock]::Create($constantAst.Extent.Text)
. $constantDefinition
$acceptedCodeHex = @($WingetExportOkCodes | ForEach-Object { '{0:X8}' -f $_ }) -join ','
if ($acceptedCodeHex -cne '00000000,8A150035') {
    throw "Unexpected accepted winget export status codes: $acceptedCodeHex"
}
$script:Scenario = $null
$script:LastWingetArgs = @()
$script:LastExportPath = $null

function global:winget {
    $script:LastWingetArgs = @($args)
    $outputIndex = [Array]::IndexOf([object[]]$args, '-o')
    if ($outputIndex -lt 0 -or $outputIndex + 1 -ge $args.Count) {
        throw 'mock winget did not receive -o PATH'
    }
    $outputPath = [string]$args[$outputIndex + 1]
    $script:LastExportPath = $outputPath

    switch ($script:Scenario) {
        'valid' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Git.Git"},{"PackageIdentifier":"GitHub.cli"}]}]}'
            $global:LASTEXITCODE = 0
        }
        'partial-match' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Git.Git"}]}]}'
            $global:LASTEXITCODE = [int]0x8A150035
        }
        'bad-exit' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{"Sources":[]}'
            $global:LASTEXITCODE = 7
        }
        'no-file' {
            $global:LASTEXITCODE = 0
        }
        'invalid-json' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{broken'
            $global:LASTEXITCODE = 0
        }
        'no-sources' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{}'
            $global:LASTEXITCODE = 0
        }
        'empty-sources' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{"Sources":[]}'
            $global:LASTEXITCODE = 0
        }
        'no-packages-property' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{"Sources":[{"SourceDetails":{"Name":"winget"}}]}'
            $global:LASTEXITCODE = 0
        }
        'empty-packages' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[]}]}'
            $global:LASTEXITCODE = 0
        }
        'missing-package-id' {
            Set-Content -LiteralPath $outputPath -Encoding utf8 -Value '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{}]}]}'
            $global:LASTEXITCODE = 0
        }
        default { throw "unknown mock scenario: $script:Scenario" }
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "ASSERT: $Message (actual=[$Actual], expected=[$Expected])"
    }
}

function Invoke-Case {
    param(
        [string]$Name,
        [bool]$ShouldThrow,
        [string]$ExpectedIds = ''
    )
    $script:Scenario = $Name
    $script:LastExportPath = $null
    $caught = $null
    $ids = @()
    try {
        $ids = @(Get-WingetInventory)
    }
    catch {
        $caught = $_
    }

    if ($ShouldThrow -and -not $caught) { throw "ASSERT: $Name should throw" }
    if (-not $ShouldThrow -and $caught) { throw "ASSERT: $Name unexpectedly threw: $caught" }
    if (-not $ShouldThrow) { Assert-Equal ($ids -join ',') $ExpectedIds "$Name IDs" }
    if ($script:LastExportPath -and (Test-Path -LiteralPath $script:LastExportPath)) {
        throw "ASSERT: $Name left temp file behind: $script:LastExportPath"
    }
    [pscustomobject]@{
        Scenario = $Name
        Outcome = if ($caught) { 'threw' } else { 'returned' }
        IDs = $ids -join ','
        Error = if ($caught) { $caught.Exception.Message } else { '' }
        Cleaned = $true
    }
}

$results = @(
    Invoke-Case valid $false 'Git.Git,GitHub.cli'
)
$expectedArgs = 'export|-o|{PATH}|--source|winget|--accept-source-agreements|--disable-interactivity'
$actualArgs = @($script:LastWingetArgs) -join '|'
$actualArgs = $actualArgs.Replace([string]$script:LastExportPath, '{PATH}')
Assert-Equal $actualArgs $expectedArgs 'winget export arguments'

$results += Invoke-Case partial-match $false 'Git.Git'
$results += Invoke-Case bad-exit $true
$results += Invoke-Case no-file $true
$results += Invoke-Case invalid-json $true
$results += Invoke-Case no-sources $true
$results += Invoke-Case empty-sources $false ''
$results += Invoke-Case no-packages-property $true
$results += Invoke-Case empty-packages $true
$results += Invoke-Case missing-package-id $true

$results | Format-Table -AutoSize
Write-Output 'ALL ASSERTIONS PASSED'
