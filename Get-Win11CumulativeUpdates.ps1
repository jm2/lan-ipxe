<#
    .SYNOPSIS
    Fetches the latest monthly Cumulative Update (and any required checkpoint
    prerequisites) for a specified Windows 11 version from the Microsoft Update Catalog.

    .DESCRIPTION
    Starting with Windows 11 24H2, Microsoft introduced "checkpoint" cumulative updates.
    A monthly CU may require one or more predecessor checkpoint CUs to be installed first.
    DISM can automatically resolve these dependencies when ALL required packages are placed
    in a single folder and /PackagePath points to that folder.

    This script queries the Update Catalog, identifies all valid CUs for the target
    version, downloads the latest monthly CU plus all earlier CUs published in the same
    release cycle (which serve as potential checkpoint prerequisites), and also fetches
    any Servicing Stack Updates (SSUs) for the target version.

    .EXAMPLE
    .\Get-Win11CumulativeUpdates.ps1 -Version "25H2" -DownloadPath "C:\Temp\Win11_Updates"
#>

#Requires -Version 7.0

[CmdletBinding()]
param (
    [string]$Version = "25H2",
    [string]$DownloadPath = 'C:\Temp\Win11_Updates'
)

if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

# ============================================================
# Helper: Search the catalog, filter results, return metadata
# ============================================================
function Find-CatalogUpdates {
    param (
        [string]$Query,
        [string[]]$ExcludePatterns = @(),
        [string]$RequirePattern = ""
    )

    $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Query))"

    try {
        $SearchPage = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing
    } catch {
        Write-Warning "Failed to query catalog for '$Query': $_"
        return @()
    }

    $UpdateIds = [regex]::Matches($SearchPage.Content, "goToDetails\(['\`"]([a-f0-9\-]+)['\`"]\)") |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique

    if (-not $UpdateIds) { return @() }

    # Parallel detail page fetches — ~10x faster than sequential
    $RawResults = $UpdateIds | ForEach-Object -Parallel {
        $Id = $_
        $DetailsUrl = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$Id"
        try {
            $DetailsPage = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -ErrorAction SilentlyContinue
            $Content = $DetailsPage.Content

            $Title = if ($Content -match 'id="ScopedViewHandler_titleText">([^<]+)') { $matches[1].Trim() }
            $DateString = if ($Content -match 'id="ScopedViewHandler_date">([^<]+)') { $matches[1].Trim() }

            if ($Title -and $DateString) {
                $DateObj = [datetime]::Parse($DateString)
                [PSCustomObject]@{
                    Title   = $Title
                    DateObj = $DateObj
                    Id      = $Id
                }
            }
        }
        catch {}
    } -ThrottleLimit 8

    # Apply filters on the collected results (can't filter inside -Parallel easily
    # since $ExcludePatterns/$RequirePattern are outer-scope variables)
    $Results = @()
    foreach ($r in $RawResults) {
        if (-not $r) { continue }
        $skip = $false
        foreach ($pattern in $ExcludePatterns) {
            if ($r.Title -match $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }
        if ($RequirePattern -and $r.Title -notmatch $RequirePattern) { continue }
        $Results += $r
    }

    return $Results
}

# Helper: Download a package from the catalog by Update ID
function Get-CatalogPackage {
    param (
        [PSCustomObject]$Update,
        [string]$DestinationPath
    )

    $PostData = "[{`"size`":0,`"updateID`":`"$($Update.Id)`",`"uidInfo`":`"$($Update.Id)`"}]"
    try {
        $DownloadPage = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method Post -Body @{updateIDs = $PostData } -UseBasicParsing
    } catch {
        Write-Warning "   [!] Failed to get download link for: $($Update.Title)"
        return $null
    }

    # The DownloadDialog page may contain multiple URLs (SSU, checkpoint prereqs, actual CU).
    # For checkpoint-era CUs (24H2+), the actual target .msu is typically the last link.
    $AllUrls = @([regex]::Matches($DownloadPage.Content, 'https://[^''"<]+\.(msu|cab)') |
               ForEach-Object { $_.Value })

    if (-not $AllUrls) {
        Write-Warning "   [!] Could not extract download URL for: $($Update.Title)"
        return $null
    }

    # Prefer the last .msu URL (the actual CU payload, not the prerequisite/SSU)
    $MsuUrls = @($AllUrls | Where-Object { $_ -match '\.msu$' })
    $DownloadUrl = if ($MsuUrls.Count -gt 0) { $MsuUrls[-1] } else { $AllUrls[-1] }

    $FileName = ($DownloadUrl -split '/')[-1]
    $OutFile = Join-Path $DestinationPath $FileName
    $HashFile = "$OutFile.sha256"

    # Check if file already exists and passes integrity verification
    if (Test-Path $OutFile) {
        if (Test-Path $HashFile) {
            $expectedHash = (Get-Content $HashFile -Raw).Trim()
            $actualHash = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
            if ($actualHash -eq $expectedHash) {
                Write-Host "   -> Verified (SHA256): $FileName" -ForegroundColor DarkGray
                return $OutFile
            }
            else {
                Write-Host "   -> Hash mismatch for $FileName — re-downloading..." -ForegroundColor Yellow
                Remove-Item $OutFile -Force
                Remove-Item $HashFile -Force
            }
        }
        else {
            # File exists but no sidecar — can't verify, re-download
            Write-Host "   -> No hash sidecar for $FileName — re-downloading..." -ForegroundColor Yellow
            Remove-Item $OutFile -Force
        }
    }

    Write-Host "   -> Downloading $FileName..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutFile -UseBasicParsing

    # Write SHA256 sidecar for future verification
    $hash = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
    Set-Content -Path $HashFile -Value $hash -NoNewline
    Write-Host "   -> Download complete: $FileName (SHA256: $($hash.Substring(0,12))...)" -ForegroundColor Green

    return $OutFile
}

# ============================================================
# 1. Fetch Cumulative Updates
# ============================================================
Write-Host "`n=> Investigating Microsoft Update Catalog for Windows 11 Version $Version Cumulative Updates..." -ForegroundColor Cyan

$Query = "Cumulative Update Windows 11 $Version x64"
Write-Host "   -> Querying Update Catalog..." -NoNewline

$CUResults = Find-CatalogUpdates -Query $Query `
    -ExcludePatterns @("(?i)\.NET", "(?i)Dynamic", "(?i)Preview", "(?i)Server") `
    -RequirePattern "(?i)for x64-based Systems"

Write-Host " Done."

if (-not $CUResults) {
    Write-Host "   [!] No valid Cumulative Updates found for Windows 11 Version $Version." -ForegroundColor Yellow
    exit 0
}

# Sort by date descending and deduplicate by Update ID
$SortedCUs = $CUResults | Sort-Object DateObj -Descending
$AllCUs = $SortedCUs | Group-Object Id | ForEach-Object { $_.Group[0] }

$TargetCU = $AllCUs | Sort-Object DateObj -Descending | Select-Object -First 1

Write-Host "   -> Target CU: $($TargetCU.Title) ($($TargetCU.DateObj.ToString('yyyy-MM-dd')))" -ForegroundColor Green
Write-Host "   -> Catalog returned $($AllCUs.Count) total CU entries." -ForegroundColor DarkGray

# ============================================================
# Checkpoint CU Discovery (24H2+)
# ============================================================
# Monthly CUs are cumulative within their checkpoint window, so intermediate
# monthly CUs (Jan, Feb, Mar between checkpoints) are fully superseded by the
# target. We only need the TARGET + any CHECKPOINT prerequisites.
#
# Strategy: search the catalog specifically for checkpoint CU packages.
# Microsoft titles checkpoints as "Checkpoint Cumulative Update" rather than
# the standard "Cumulative Update" used for monthly CUs. If no dedicated
# checkpoint search produces results, fall back to including the oldest CU
# from the standard results (which is typically the first checkpoint).
# ============================================================

Write-Host "   -> Searching for checkpoint prerequisites..." -NoNewline

$CheckpointQuery = "Checkpoint Cumulative Update Windows 11 $Version x64"
$CheckpointResults = Find-CatalogUpdates -Query $CheckpointQuery `
    -ExcludePatterns @("(?i)\.NET", "(?i)Dynamic", "(?i)Preview", "(?i)Server") `
    -RequirePattern "(?i)for x64-based Systems"

Write-Host " Done."

$PackagesToDownload = @()
$PackagesToDownload += $TargetCU

if ($CheckpointResults) {
    $CheckpointCUs = $CheckpointResults | Sort-Object DateObj -Descending |
                     Group-Object Id | ForEach-Object { $_.Group[0] }

    # Only include checkpoints that are OLDER than the target (prerequisites)
    $CheckpointCUs = $CheckpointCUs | Where-Object { $_.DateObj -lt $TargetCU.DateObj }

    foreach ($cp in $CheckpointCUs) {
        $PackagesToDownload += $cp
    }
    Write-Host "   -> Found $($CheckpointCUs.Count) checkpoint prerequisite(s) from catalog." -ForegroundColor Yellow
}
else {
    # Fallback: no dedicated checkpoint search results.
    # Include the oldest CU from standard results as the likely checkpoint base.
    $OldestCU = $AllCUs | Sort-Object DateObj | Select-Object -First 1
    if ($OldestCU.Id -ne $TargetCU.Id) {
        $PackagesToDownload += $OldestCU
        Write-Host "   -> No checkpoint-specific results. Including oldest CU as fallback checkpoint base." -ForegroundColor Yellow
    }
}

# Deduplicate and sort chronologically
$PackagesToDownload = $PackagesToDownload | Sort-Object Id -Unique | Sort-Object DateObj

$skippedCount = $AllCUs.Count - $PackagesToDownload.Count
Write-Host "   -> Selected $($PackagesToDownload.Count) package(s), $skippedCount intermediate monthly CUs skipped." -ForegroundColor Yellow

foreach ($pkg in $PackagesToDownload) {
    $role = if ($pkg.Id -eq $TargetCU.Id) { "TARGET" } else { "CHECKPOINT" }
    Write-Host "      [$role] $($pkg.Title) ($($pkg.DateObj.ToString('yyyy-MM-dd')))" -ForegroundColor DarkGray
}

$downloadedCount = 0
$downloadedFiles = @{}
foreach ($cu in $PackagesToDownload) {
    $result = Get-CatalogPackage -Update $cu -DestinationPath $DownloadPath
    if ($result) {
        $fileName = Split-Path $result -Leaf
        if (-not $downloadedFiles.ContainsKey($fileName)) {
            $downloadedFiles[$fileName] = $true
            $downloadedCount++
        }
    }
}

# ============================================================
# 2. Fetch Servicing Stack Updates (SSU) if available
# ============================================================
Write-Host "`n=> Checking for Servicing Stack Updates for Windows 11 $Version..." -ForegroundColor Cyan

$SSUQuery = "Servicing Stack Update Windows 11 $Version x64"
Write-Host "   -> Querying..." -NoNewline

$SSUResults = Find-CatalogUpdates -Query $SSUQuery `
    -ExcludePatterns @("(?i)Server") `
    -RequirePattern "(?i)for x64-based Systems"

Write-Host " Done."

if ($SSUResults) {
    $BestSSU = $SSUResults | Sort-Object DateObj -Descending | Select-Object -First 1
    Write-Host "   -> SSU Found: $($BestSSU.Title) ($($BestSSU.DateObj.ToString('yyyy-MM-dd')))" -ForegroundColor Green
    $result = Get-CatalogPackage -Update $BestSSU -DestinationPath $DownloadPath
    if ($result) { $downloadedCount++ }
}
else {
    Write-Host "   -> No standalone SSU found (likely integrated into CU packages)." -ForegroundColor DarkGray
}

# ============================================================
# Summary
# ============================================================
$totalPackages = Get-ChildItem -Path $DownloadPath -Include *.msu,*.cab -Recurse
Write-Host "`n=> Summary: $($totalPackages.Count) package(s) ready in $DownloadPath" -ForegroundColor Cyan
foreach ($pkg in $totalPackages) {
    Write-Host "   - $($pkg.Name)" -ForegroundColor DarkGray
}
Write-Host "`nProcess complete. Point DISM /Add-Package /PackagePath at this folder for automatic dependency resolution." -ForegroundColor Cyan
