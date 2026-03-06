<#
    .SYNOPSIS
    Fetches and optionally installs the absolute latest Qualcomm Wi-Fi drivers 
    directly from the Microsoft Update Catalog.

    .DESCRIPTION
    This script queries the Catalog for Qualcomm Wi-Fi adapters (QCA6390, WCN6855, WCN7850),
    pulls the detailed version for every package, and prioritizes packages using 
    standard Semantic Versioning (e.g., 2.0.0.x or 3.0.0.x), while explicitly ignoring
    older "NDIS" legacy titles to guarantee modern NetAdapterCx or modern WDI drivers.

    .EXAMPLE
    .\Get-QualcommWiFiDrivers.ps1
    Downloads and extracts the newest drivers to C:\Temp\Qualcomm_WiFi without installing.

    .EXAMPLE
    .\Get-QualcommWiFiDrivers.ps1 -Install
    Downloads, extracts, installs the drivers to the Driver Store, and cleans up the CABs.
#>

[CmdletBinding()]
param (
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp\Qualcomm_WiFi'
)

# Dynamic Admin Check
if ($Install -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "The -Install flag requires Administrator privileges. Please run PowerShell as Administrator."
    return
}

$Targets = @(
    @{ 
        Name    = "Qualcomm_PCIe_Family" 
        Devices = @(
            @{ 
                ModelId         = "1101"
                ModelName       = "QCA6390"
                Queries         = @("VEN_17CB&DEV_1101", "FastConnect 6800", "Killer AX500")
                PreferredBranch = "3.0"
            },
            @{ 
                ModelId         = "1103"
                ModelName       = "WCN6855"
                Queries         = @("VEN_17CB&DEV_1103", "FastConnect 6900", "WCN6855", "QCNFA765")
                PreferredBranch = "3.0"
            },
            @{ 
                ModelId         = "1107"
                ModelName       = "WCN7850"
                Queries         = @("VEN_17CB&DEV_1107", "FastConnect 7800", "NCM865", "WCN7850")
                PreferredBranch = "3.1"
            }
        )
    }
)


if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

foreach ($Target in $Targets) {
    Write-Host "`n=> Investigating Microsoft Update Catalog for $($Target.Name)..." -ForegroundColor Cyan
    
    $AvailablePackages = @()

    foreach ($Device in $Target.Devices) {
        $ModelId = $Device.ModelId

        foreach ($Query in $Device.Queries) {
            Write-Host "   -> Searching for ModelId $ModelId ($Query)..."
            
            $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Query))"
            $SearchPage = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing
            
            # Extract all update IDs from the search results table
            $UpdateIds = [regex]::Matches($SearchPage.Content, "goToDetails\(['""]([a-f0-9\-]+)['""]\)") | 
            ForEach-Object { $_.Groups[1].Value } | 
            Select-Object -Unique

            if (-not $UpdateIds) {
                Write-Host "      [!] No candidates found for this query." -ForegroundColor Yellow
                continue
            }

            Write-Host "      -> Found $($UpdateIds.Count) packages for query '$Query'. Fetching deep versions..." -NoNewline
            $counter = 0

            foreach ($Id in $UpdateIds) {
                $counter++
                if ($counter % 5 -eq 0) { Write-Host "." -NoNewline }
            
                $DetailsUrl = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$Id"
                try {
                    $DetailsPage = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -ErrorAction SilentlyContinue
                    $DateString = if ($DetailsPage.Content -match "id=`"ScopedViewHandler_versionDate`">([^<]+)") { $matches[1].Trim() }
                    $Version = if ($DetailsPage.Content -match "id=`"ScopedViewHandler_version`">([^<]+)") { $matches[1].Trim() }
                
                    $Title = if ($DetailsPage.Content -match "id=`"ScopedViewHandler_titleText`">([^<]+)") { $matches[1].Trim() }
                
                    if ($Version -and $DateString -and $Title -notmatch "NDIS") {
                        try {
                            $DateObj = [datetime]::Parse($DateString)
                            $Arch = if ($DetailsPage.Content -match "ARM64") { "ARM64" } elseif ($DetailsPage.Content -match "AMD64") { "AMD64" } else { "x86" }
                            $AvailablePackages += [PSCustomObject]@{
                                ModelId         = $ModelId
                                ModelName       = $Device.ModelName
                                Version         = [version]$Version
                                DateObj         = $DateObj
                                Id              = $Id
                                Title           = $Title
                                PreferredBranch = $Device.PreferredBranch
                                Arch            = $Arch
                            }
                        }
                        catch {}
                    }
                }
                catch {}
            }
            Write-Host " Done."
        }
    }
    
    if (-not $AvailablePackages) {
        Write-Host "   [!] No matching ModelIds found within candidate packages." -ForegroundColor Yellow
        continue
    }

    # Group all valid candidate packages into their correct respective HWModelId families and Architecture, and find the freshest.
    $GroupedPackages = $AvailablePackages | Group-Object ModelId, Arch
    
    foreach ($Group in $GroupedPackages) {
        $FirstObj = $Group.Group[0]
        $ModelId = $FirstObj.ModelId
        $Arch = $FirstObj.Arch
        $ModelName = $FirstObj.ModelName
        
        # Check if any packages exactly match the preferred major.minor branch 
        $TargetBranch = $FirstObj.PreferredBranch
        $BranchMatches = $Group.Group | Where-Object { $_.Version.ToString().StartsWith("$TargetBranch.") }
        
        if ($BranchMatches.Count -gt 0) {
            $BestPackage = $BranchMatches | Sort-Object Version -Descending | Select-Object -First 1
            Write-Host "   -> ModelId $($ModelId) [$Arch]: Selected v$($BestPackage.Version) [Preferred Branch] (Update ID: $($BestPackage.Id))" -ForegroundColor Green
        }
        else {
            $BestPackage = $Group.Group | Sort-Object Version -Descending | Select-Object -First 1
            Write-Host "   -> ModelId $($ModelId) [$Arch]: Selected v$($BestPackage.Version) [Global Highest] (Update ID: $($BestPackage.Id))" -ForegroundColor Green
        }
        
        $PostData = "[{`"size`":0,`"updateID`":`"$($BestPackage.Id)`",`"uidInfo`":`"$($BestPackage.Id)`"}]"
        $DownloadPage = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method Post -Body @{updateIDs = $PostData } -UseBasicParsing
        
        $CabUrl = [regex]::Match($DownloadPage.Content, 'https://[^''"<]+\.cab').Value
        
        if (-not $CabUrl) {
            Write-Host "      [!] Could not extract .cab URL from payload." -ForegroundColor Red
            continue
        }
        
        $CabFile = Join-Path $DownloadPath "$($Target.Name)_$($ModelId)_$($Arch).cab"
        $ExtractDir = Join-Path $DownloadPath "$($Target.Name)\$ModelName\$Arch"
        
        Write-Host "      -> Downloading raw $Arch driver package..."
        Invoke-WebRequest -Uri $CabUrl -OutFile $CabFile -UseBasicParsing
        
        Write-Host "      -> Extracting payload using expand.exe..."
        if (-not (Test-Path $ExtractDir)) { New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null }
        
        Start-Process "expand.exe" -ArgumentList "-F:* `"$CabFile`" `"$ExtractDir`"" -Wait -NoNewWindow -PassThru | Out-Null
        Remove-Item $CabFile -Force
        
        if ($Install) {
            $SysArch = $env:PROCESSOR_ARCHITECTURE
            if ($SysArch -eq $Arch) {
                Write-Host "      -> System is $SysArch. Injecting $Arch driver into Driver Store via pnputil..." -ForegroundColor Green
                pnputil.exe /add-driver "$ExtractDir\*.inf" /install | Out-Null
                Write-Host "      -> Injection complete." -ForegroundColor Green
            }
            else {
                Write-Host "      -> System is $SysArch. Skipping $Arch driver installation." -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "      -> Extracted to: $ExtractDir (Skipping installation)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`nProcess complete." -ForegroundColor Cyan