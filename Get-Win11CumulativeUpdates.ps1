<#
    .SYNOPSIS
    Fetches the absolute latest monthly Cumulative Update for a specified Windows 11 Version 
    directly from the Microsoft Update Catalog.

    .DESCRIPTION
    This script queries the Update Catalog, pulls the detailed version for candidates,
    filters out .NET, Dynamic, and Preview updates, and downloads the absolute newest 
    monthly Cumulative Update (.msu) for the targeted OS.

    .EXAMPLE
    .\Get-Win11CumulativeUpdates.ps1 -Version "24H2" -DownloadPath "C:\Temp\Win11_Updates"
#>

[CmdletBinding()]
param (
    [string]$Version = "25H2",
    [string]$DownloadPath = 'C:\Temp\Win11_Updates'
)

if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

Write-Host "`n=> Investigating Microsoft Update Catalog for Windows 11 Version $Version Cumulative Updates..." -ForegroundColor Cyan

$Query = "Cumulative Update Windows 11 $Version x64"
$SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Query))"

Write-Host "   -> Querying Update Catalog..."
try {
    $SearchPage = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing
} catch {
    Write-Error "Failed to query catalog: $_"
    exit 1
}

# Extract all update IDs from the search results table
$UpdateIds = [regex]::Matches($SearchPage.Content, "goToDetails\(['""]([a-f0-9\-]+)['""]\)") | 
ForEach-Object { $_.Groups[1].Value } | 
Select-Object -Unique

if (-not $UpdateIds) {
    Write-Host "   [!] No candidates found for Windows 11 Version $Version." -ForegroundColor Yellow
    exit 0
}

Write-Host "   -> Found $($UpdateIds.Count) packages. Evaluating candidates..." -NoNewline

$AvailableUpdates = @()
$counter = 0

foreach ($Id in $UpdateIds) {
    $counter++
    if ($counter % 5 -eq 0) { Write-Host "." -NoNewline }
    
    $DetailsUrl = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$Id"
    try {
        $DetailsPage = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -ErrorAction SilentlyContinue
        $Content = $DetailsPage.Content
        
        $Title = if ($Content -match "id=`"ScopedViewHandler_title`">([^<]+)") { $matches[1].Trim() }
        $DateString = if ($Content -match "id=`"ScopedViewHandler_date`">([^<]+)") { $matches[1].Trim() }
        
        if ($Title -and $DateString) {
            # Filter out unwanted updates
            if ($Title -match "(?i)\.NET" -or 
                $Title -match "(?i)Dynamic" -or 
                $Title -match "(?i)Preview" -or
                $Title -match "(?i)Server" -or
                $Title -notmatch "(?i)for x64-based Systems") {
                continue
            }
            
            try {
                $DateObj = [datetime]::Parse($DateString)
                $AvailableUpdates += [PSCustomObject]@{
                    Title   = $Title
                    DateObj = $DateObj
                    Id      = $Id
                }
            }
            catch {}
        }
    }
    catch {}
}
Write-Host " Done."

if (-not $AvailableUpdates) {
    Write-Host "   [!] No valid Cumulative Updates found after filtering." -ForegroundColor Yellow
    exit 0
}

# Find the freshest update
$BestUpdate = $AvailableUpdates | Sort-Object DateObj -Descending | Select-Object -First 1
Write-Host "   -> Selected: $($BestUpdate.Title) ($($BestUpdate.DateObj.ToString('yyyy-MM-dd')))" -ForegroundColor Green

$PostData = "[{`"size`":0,`"updateID`":`"$($BestUpdate.Id)`",`"uidInfo`":`"$($BestUpdate.Id)`"}]"
$DownloadPage = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method Post -Body @{updateIDs = $PostData } -UseBasicParsing

$DownloadUrl = [regex]::Match($DownloadPage.Content, 'https://[^''"<]+\.(msu|cab)').Value

if (-not $DownloadUrl) {
    Write-Host "   [!] Could not extract download URL from payload." -ForegroundColor Red
    exit 1
}

$FileName = ($DownloadUrl -split '/')[-1]
$OutFile = Join-Path $DownloadPath $FileName

if (Test-Path $OutFile) {
    Write-Host "   -> Update package already downloaded: $OutFile" -ForegroundColor DarkGray
} else {
    Write-Host "   -> Downloading $FileName..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutFile -UseBasicParsing
    Write-Host "   -> Download complete: $OutFile" -ForegroundColor Green
}

Write-Host "`nProcess complete." -ForegroundColor Cyan
