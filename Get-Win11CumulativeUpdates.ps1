<#
    .SYNOPSIS
    Fetches the latest monthly Cumulative Update (and any required checkpoint
    prerequisites) for a specified Windows 11 version from the Microsoft Update Catalog.

    .DESCRIPTION
    Starting with Windows 11 24H2, Microsoft introduced "checkpoint" cumulative updates.
    A monthly CU may require one or more predecessor checkpoint CUs to be installed first.
    DISM can automatically resolve these dependencies when ALL required packages are placed
    in a single folder and /PackagePath points to that folder.

    This script queries the Update Catalog, identifies the latest monthly CU for the
    target version, and downloads every .msu its DownloadDialog returns — for
    checkpoint-era CUs (24H2+) Microsoft bundles the full required checkpoint chain
    there. All packages land in one folder so DISM can resolve the dependency chain
    automatically. It also fetches any Servicing Stack Updates (SSUs) for the version.

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
# Helper: retry-with-backoff wrapper around Invoke-WebRequest
# ============================================================
# The Update Catalog throttles aggressively; transient 429/5xx/timeout failures are
# common. Retry up to 3 times with an increasing delay, then re-throw so callers can
# try/catch and skip cleanly. NOTE: this runs only on the main thread — it is NOT
# available inside ForEach-Object -Parallel runspaces, which carry their own inline
# retry loop.
function Invoke-CatalogRequest {
    param (
        [Parameter(Mandatory)][hashtable]$Params,
        [int]$MaxAttempts = 3
    )
    # Bounded timeout + browser UA so a stalled catalog connection can't hang the run
    # (callers can override TimeoutSec, e.g. the large .msu download).
    if (-not $Params.ContainsKey('TimeoutSec')) { $Params['TimeoutSec'] = 60 }
    if (-not $Params.ContainsKey('UserAgent')) { $Params['UserAgent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) lan-ipxe-catalog-scrape' }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-WebRequest @Params
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

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

    $SearchPage = $null
    try {
        $SearchPage = Invoke-CatalogRequest -Params @{ Uri = $SearchUrl; UseBasicParsing = $true }
    } catch {
        Write-Warning "Failed to query catalog for '$Query': $_"
        return @()
    }

    # LIMITATION: Search.aspx returns only the first 25 relevance-sorted rows. Picking
    # "newest by date" below therefore only sees the first 25. Full pagination requires
    # __EVENTTARGET POST-backs (invasive); for now we parse the "1 - N of M" total and
    # warn when M > 25 so a missed newer entry is at least visible.
    if ($SearchPage.Content -match '(\d+)\s*-\s*(\d+)\s+of\s+(\d+)') {
        $totalResults = [int]$matches[3]
        if ($totalResults -gt 25) {
            Write-Warning "Catalog reports $totalResults results for '$Query' but only the first 25 are parsed (pagination not implemented)."
        }
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
            # Inline retry-with-backoff (the script-scope helper is not visible here).
            $DetailsPage = $null
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try { $DetailsPage = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -TimeoutSec 60 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) lan-ipxe-catalog-scrape'; break }
                catch { if ($attempt -ge 3) { throw } else { Start-Sleep -Seconds ($attempt * 2) } }
            }
            $Content = $DetailsPage.Content

            $Title = if ($Content -match 'id="ScopedViewHandler_titleText">([^<]+)') { $matches[1].Trim() }
            $DateString = if ($Content -match 'id="ScopedViewHandler_date">([^<]+)') { $matches[1].Trim() }

            if ($Title -and $DateString) {
                # Locale-independent parse: the catalog serves US M/d/yyyy. Plain [datetime]::Parse
                # is CurrentCulture-bound, so on a non-US host a day>12 throws (caught below -> the
                # CU is silently dropped, possibly the newest) and day<=12 silently swaps day/month.
                $DateObj = [datetime]::ParseExact($DateString, [string[]]@('M/d/yyyy', 'MM/dd/yyyy'), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None)
                [PSCustomObject]@{
                    Title   = $Title
                    DateObj = $DateObj
                    Id      = $Id
                }
            }
        }
        catch {
            Write-Warning "Detail fetch/parse failed for update $Id : $($_.Exception.Message)"
        }
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

# Helper: Download ALL packages the catalog lists for one Update ID.
# Returns an array of [PSCustomObject]@{ Path; FileName; IsTarget }.
function Get-CatalogPackage {
    param (
        [PSCustomObject]$Update,
        [string]$DestinationPath,
        [string]$TargetKB = ""
    )

    $PostData = "[{`"size`":0,`"updateID`":`"$($Update.Id)`",`"uidInfo`":`"$($Update.Id)`"}]"
    try {
        $DownloadPage = Invoke-CatalogRequest -Params @{ Uri = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"; Method = 'Post'; Body = @{updateIDs = $PostData }; UseBasicParsing = $true }
    } catch {
        Write-Warning "   [!] Failed to get download link for: $($Update.Title)"
        return @()
    }

    # FIX: the DownloadDialog can list MULTIPLE packages for one update ID. For
    # checkpoint-era CUs (24H2+) it returns the ENTIRE required checkpoint chain
    # (several .msu), and the actual target is NOT reliably the last link (the checkpoint's
    # position varies — observed FIRST for 25H2, LAST for 24H2). Download ALL into one folder so DISM
    # can resolve the dependency chain automatically, and identify the target by the
    # KB number rather than by list position.
    $AllUrls = @([regex]::Matches($DownloadPage.Content, 'https://[^''"<]+\.(msu|cab)') |
               ForEach-Object { $_.Value } | Select-Object -Unique)

    if (-not $AllUrls) {
        Write-Warning "   [!] Could not extract any download URL for: $($Update.Title)"
        return @()
    }

    $Downloaded = @()
    foreach ($DownloadUrl in $AllUrls) {
        $FileName = ($DownloadUrl -split '/')[-1]
        $OutFile = Join-Path $DestinationPath $FileName
        $HashFile = "$OutFile.sha256"
        # Anchor on the surrounding boundary so a shorter KB can't prefix-match a longer one
        # (e.g. KB5012 vs KB50123); catalog filenames are windows11.0-kb<num>-x64_...
        $IsTarget = [bool]($TargetKB -and ($FileName -match "(?i)kb$([regex]::Escape($TargetKB))(?:\D|$)"))

        # NOTE: the SHA256 sidecar below is a LOCAL CACHE / CORRUPTION check only. It
        # confirms the file still matches what we previously downloaded (detects
        # truncated/partial downloads and bit-rot); it does NOT establish authenticity,
        # because the hash is self-generated, not published by Microsoft. Authenticity
        # is checked separately via Get-AuthenticodeSignature below.
        if (Test-Path $OutFile) {
            if (Test-Path $HashFile) {
                $expectedHash = (Get-Content $HashFile -Raw).Trim()
                $actualHash = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
                if ($actualHash -eq $expectedHash) {
                    Write-Host "   -> Cached (SHA256 cache check OK): $FileName" -ForegroundColor DarkGray
                    # Re-verify authenticity on cache reuse too: the sidecar is self-generated
                    # (byte-stability only), so it must NOT bypass the Authenticode check that the
                    # fresh-download path performs.
                    $cachedSig = Get-AuthenticodeSignature -FilePath $OutFile
                    if ($cachedSig.Status -ne 'Valid') {
                        Write-Warning "   [!] Authenticode signature for cached $FileName is '$($cachedSig.Status)' (not Valid) — treat this package as UNVERIFIED before servicing."
                    }
                    $Downloaded += [PSCustomObject]@{ Path = $OutFile; FileName = $FileName; IsTarget = $IsTarget }
                    continue
                }
                else {
                    Write-Host "   -> Local cache hash mismatch for $FileName — re-downloading..." -ForegroundColor Yellow
                    Remove-Item $OutFile -Force
                    Remove-Item $HashFile -Force
                }
            }
            else {
                # File exists but no sidecar — can't cache-check, re-download
                Write-Host "   -> No cache sidecar for $FileName — re-downloading..." -ForegroundColor Yellow
                Remove-Item $OutFile -Force
            }
        }

        Write-Host "   -> Downloading $FileName..."
        try {
            # Large .msu (often 600 MB - 1.5 GB) — generous timeout so a slow link doesn't abort.
            Invoke-CatalogRequest -Params @{ Uri = $DownloadUrl; OutFile = $OutFile; UseBasicParsing = $true; TimeoutSec = 3600 } | Out-Null
        }
        catch {
            Write-Warning "   [!] Download failed for $FileName : $_"
            continue
        }

        # AUTHENTICITY: these .msu are servicing payloads applied to the OS image. Verify
        # the publisher's Authenticode signature. Warn (do not throw) on failure so the
        # happy path is preserved; the file is kept (skipping it would break the DISM
        # chain) but flagged loudly as UNVERIFIED.
        $sig = Get-AuthenticodeSignature -FilePath $OutFile
        if ($sig.Status -ne 'Valid') {
            Write-Warning "   [!] Authenticode signature for $FileName is '$($sig.Status)' (not Valid) — treat this package as UNVERIFIED before servicing."
        }
        else {
            Write-Host "   -> Authenticode signature valid: $FileName" -ForegroundColor DarkGray
        }

        # Local cache/corruption sidecar (NOT authenticity — see note above).
        $hash = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
        Set-Content -Path $HashFile -Value $hash -NoNewline
        Write-Host "   -> Download complete: $FileName" -ForegroundColor Green

        $Downloaded += [PSCustomObject]@{ Path = $OutFile; FileName = $FileName; IsTarget = $IsTarget }
    }

    return $Downloaded
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
# Checkpoint chain (24H2+)
# ============================================================
# FIX: Previously this section ran a separate catalog search for a
# "Checkpoint Cumulative Update ..." title. That phrase never appears in catalog
# titles, so the search always returned nothing and the code fell back to guessing
# the oldest monthly CU as the "checkpoint base" — which is wrong.
#
# The required checkpoint chain is actually delivered by the TARGET CU's own
# DownloadDialog: for checkpoint-era CUs Microsoft lists the full set of prerequisite
# .msu packages there (and the target is NOT reliably the last entry). We therefore
# download EVERY .msu the target's DownloadDialog returns into one folder and let DISM
# resolve the chain (/Add-Package /PackagePath <folder>). The target package is
# identified by the KB number parsed from its catalog title, not by list position.
# ============================================================

# Parse the KB number from the target CU title so we can positively identify the
# target .msu among the (possibly several) packages DownloadDialog returns.
$TargetKB = if ($TargetCU.Title -match '(?i)KB(\d+)') { $matches[1] } else { "" }
if ($TargetKB) {
    Write-Host "   -> Target KB parsed from title: KB$TargetKB" -ForegroundColor DarkGray
}
else {
    Write-Warning "Could not parse a KB number from the target CU title; target/prereq labelling will be best-effort."
}

Write-Host "   -> Downloading target CU and any bundled checkpoint prerequisites..." -ForegroundColor Cyan

$DownloadedPackages = @(Get-CatalogPackage -Update $TargetCU -DestinationPath $DownloadPath -TargetKB $TargetKB)

if ($DownloadedPackages.Count -gt 0) {
    foreach ($f in $DownloadedPackages) {
        $role = if ($f.IsTarget) { "TARGET" } else { "PREREQ/CHECKPOINT" }
        Write-Host "      [$role] $($f.FileName)" -ForegroundColor DarkGray
    }
    if ($TargetKB -and -not ($DownloadedPackages | Where-Object { $_.IsTarget })) {
        Write-Warning "None of the downloaded .msu filenames matched KB$TargetKB — verify the target payload is present before servicing."
    }
}
else {
    Write-Warning "No .msu packages were downloaded for the target CU ($($TargetCU.Title))."
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
    # Download the SSU into the same folder (the final summary recounts from disk).
    Get-CatalogPackage -Update $BestSSU -DestinationPath $DownloadPath | Out-Null
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
