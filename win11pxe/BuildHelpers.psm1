#Requires -Version 7.0
Set-StrictMode -Version Latest

function Resolve-PxeBootAdapter {
    param([string[]]$Guid, [object[]]$Adapters)
    $seen = [System.Collections.Generic.HashSet[guid]]::new()
    foreach ($value in $Guid) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw "Invalid boot adapter GUID: '$value'."
        }
        $foundAdapters = @($Adapters | Where-Object { $_.GUID -and [guid]$_.GUID -eq $parsed })
        if ($foundAdapters.Count -ne 1 -or -not $foundAdapters[0].ServiceName -or
            -not $foundAdapters[0].PNPDeviceID -or $foundAdapters[0].ConfigManagerErrorCode -ne 0) {
            throw "Boot adapter $parsed must be present with a working driver on the machine running DISM. A GUID copied from another machine or Windows session is insufficient."
        }
        if ($seen.Add($parsed)) {
            [pscustomobject]@{
                Guid = $parsed.ToString('B'); Name = $foundAdapters[0].Name
                ServiceName = $foundAdapters[0].ServiceName; PnpDeviceId = $foundAdapters[0].PNPDeviceID
            }
        }
    }
}

function Resolve-PxeDriverPath {
    param([string[]]$Path)
    foreach ($entry in $Path) {
        $item = Get-Item -LiteralPath $entry -ErrorAction Stop
        if ($item.PSIsContainer) {
            if (-not (Get-ChildItem -LiteralPath $item.FullName -Recurse -Filter *.inf -File | Select-Object -First 1)) {
                throw "Driver directory contains no INF files: $entry"
            }
        }
        elseif ($item.Extension -ine '.inf') { throw "DriverPath must be an INF file or an extracted driver directory: $entry" }
        $item.FullName
    }
}

function Select-PxeDriverBinary {
    param([System.IO.FileInfo[]]$Candidates)
    if (-not $Candidates.Count) { throw 'No driver binary candidates supplied.' }
    $hashes = @($Candidates | Get-FileHash -Algorithm SHA256 | Select-Object -ExpandProperty Hash -Unique)
    if ($hashes.Count -ne 1) {
        throw "Ambiguous boot driver '$($Candidates[0].Name)': different binaries exist at $($Candidates.FullName -join ', '). Use a single tested driver package; no binary was selected."
    }
    # Duplicate, byte-identical copies are common in multi-device packages.
    $Candidates | Sort-Object FullName | Select-Object -First 1
}

function Add-PxeBuildWarning {
    param([System.Collections.IDictionary]$Report, [string]$Message)
    $Report.Warnings.Add($Message)
    Write-Warning $Message
}

function Invoke-PxeDism {
    param(
        [string[]]$Arguments,
        [System.Collections.IDictionary]$Report,
        [string]$Executable = 'dism.exe'
    )
    # Inspect native exit codes ourselves, including success-with-reboot (3010).
    $PSNativeCommandUseErrorActionPreference = $false
    & $Executable @Arguments | Out-Host
    $code = $LASTEXITCODE
    $Report.DismOperations.Add([pscustomobject]@{ Arguments = $Arguments; ExitCode = $code })
    if ($code -notin 0, 3010) {
        throw "DISM $($Arguments -join ' ') failed (exit $code)."
    }
}

function Get-PxeServiceAudit {
    param([string]$RegistryPath, [string]$WindowsPath, [string]$ControlSet, [string]$Service)
    $path = Join-Path $RegistryPath "$ControlSet\Services\$Service"
    if (-not (Test-Path $path)) { return }
    $properties = Get-ItemProperty $path
    $values = @{ ImagePath = ''; Start = $null; BootFlags = 0 }
    foreach ($name in @($values.Keys)) {
        if ($properties.PSObject.Properties[$name]) { $values[$name] = $properties.$name }
    }
    $imagePath = [string]$values.ImagePath
    $relative = $imagePath -replace '^(\\SystemRoot\\|%SystemRoot%\\)', ''
    $binaryExists = $false
    if ($relative -match '^System32\\') {
        $binaryExists = Test-Path -LiteralPath (Join-Path $WindowsPath $relative) -PathType Leaf
    }
    $overrides = @{}
    if (Test-Path "$path\StartOverride") {
        $key = Get-Item "$path\StartOverride"
        try { foreach ($name in $key.GetValueNames()) { $overrides[$name] = $key.GetValue($name) } }
        finally { $key.Close() }
    }
    [pscustomobject]@{
        ControlSet = $ControlSet; Service = $Service
        Start = $values.Start; BootFlags = $values.BootFlags
        ImagePath = $imagePath; BinaryExists = $binaryExists; StartOverride = $overrides
    }
}

function Write-PxeBuildReport {
    param([System.Collections.IDictionary]$Report, [string]$Path)
    $temporary = "$Path.tmp"
    $Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
    [System.IO.File]::Move($temporary, $Path, $true)
}

function Publish-PxeImage {
    param(
        [string]$WorkingPath, [string]$OutPath, [string]$ReportPath,
        [System.Collections.IDictionary]$Report
    )
    if ($Report.State -ne 'ReadyToPublish') { throw 'Image build and cleanup must succeed before publication.' }
    # The report is per-build, so a failed run never overwrites the previous report.
    Write-PxeBuildReport $Report $ReportPath
    $backup = "$WorkingPath.previous"
    $replacing = [System.IO.File]::Exists($OutPath)
    if ($replacing) { [System.IO.File]::Replace($WorkingPath, $OutPath, $backup) }
    else { [System.IO.File]::Move($WorkingPath, $OutPath) }
    try {
        $Report.State = 'Complete'
        Write-PxeBuildReport $Report $ReportPath
    }
    catch {
        # Roll back if the completion report cannot be saved.
        if ($replacing) { [System.IO.File]::Replace($backup, $OutPath, $WorkingPath) }
        else { [System.IO.File]::Move($OutPath, $WorkingPath) }
        $Report.State = 'Failed'
        throw
    }
    if ($replacing) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function Resolve-PxeBootAdapter, Resolve-PxeDriverPath, Select-PxeDriverBinary,
    Add-PxeBuildWarning, Invoke-PxeDism, Get-PxeServiceAudit, Write-PxeBuildReport, Publish-PxeImage
