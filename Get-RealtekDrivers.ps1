<#
    .SYNOPSIS
    Fetches and optionally installs the absolute latest Realtek NetAdapterCx (11.x) drivers for 
    all modern PCIe and USB Realtek NIC families directly from the Microsoft Update Catalog.

    .DESCRIPTION
    Realtek driver Versioning is based on an OS/Hardware matrix suffix, not pure chronology.
    e.g. 1168 (PCIe 1G) > 1159 (USB 10G) incorrectly looks newer, but they are different hardware.
    The true release date is encoded at the end: Prefix.Revision.MMDD.YYYY (or YY.MMDD).
    This script queries the Catalog, pulls the detailed version for every package, decodes
    the true release date, and downloads the absolute newest driver for each specific HW family.

    .EXAMPLE
    .\Get-RealtekDrivers.ps1
    Downloads and extracts the newest drivers to C:\Temp\Realtek_NetAdapterCx without installing.

    .EXAMPLE
    .\Get-RealtekDrivers.ps1 -Install
    Downloads, extracts, installs the drivers to the Driver Store, and cleans up the CABs.
#>

[CmdletBinding()]
param (
    [switch]$Install
)

# Dynamic Admin Check
if ($Install -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "The -Install flag requires Administrator privileges. Please run PowerShell as Administrator."
    return
}

function Get-RealtekDriverDate {
    param([string]$Version)
    # PCIE style: Prefix.Rev.MMDD.YYYY (e.g. 1125.14.816.2025)
    if ($Version -match "\.(0?[1-9]|1[0-2])([0-2]\d|3[01])\.(20\d\d)$") {
        return [int]("$($matches[3])$($matches[1].PadLeft(2, '0'))$($matches[2])")
    } 
    # USB style: Prefix.Rev.YY.MMDD (e.g. 1159.21.20.1009 means 2020-10-09)
    elseif ($Version -match "\.(2\d|3\d)\.(0?[1-9]|1[0-2])([0-2]\d|3[01])$") {
        return [int]("20$($matches[1])$($matches[2].PadLeft(2, '0'))$($matches[3])")
    }
    return 0
}

$Targets = @(
    @{ 
        Name    = "RTL_PCIe_Family" 
        Devices = @(
            @{ Prefix = "1125"; HWID = "VEN_10EC&DEV_8125" },
            @{ Prefix = "1126"; HWID = "VEN_10EC&DEV_8126" },
            @{ Prefix = "1127"; HWID = "VEN_10EC&DEV_8127" },
            @{ Prefix = "1168"; HWID = "VEN_10EC&DEV_8168" }
        )
    },
    @{ 
        Name    = "RTL_USB_Family"
        Devices = @(
            @{ Prefix = "1153"; HWID = "VID_0BDA&PID_8153" },
            @{ Prefix = "1156"; HWID = "VID_0BDA&PID_8156" },
            @{ Prefix = "1157"; HWID = "VID_0BDA&PID_8157" },
            @{ Prefix = "1159"; HWID = "VID_0BDA&PID_815A" }
        )
    }
)

$TempDir = "C:\Temp\Realtek_NetAdapterCx"
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

foreach ($Target in $Targets) {
    Write-Host "`n=> Investigating Microsoft Update Catalog for $($Target.Name)..." -ForegroundColor Cyan
    
    $AvailablePackages = @()

    foreach ($Device in $Target.Devices) {
        $Prefix = $Device.Prefix
        $HWID = $Device.HWID
        $Query = "$HWID Windows 11"
        Write-Host "   -> Searching specific HWID for Prefix $Prefix ($Query)..."
        
        $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Query))"
        $SearchPage = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing
        
        # Extract all update IDs from the search results table
        $UpdateIds = [regex]::Matches($SearchPage.Content, "goToDetails\(['""]([a-f0-9\-]+)['""]\)") | 
        ForEach-Object { $_.Groups[1].Value } | 
        Select-Object -Unique

        if (-not $UpdateIds) {
            Write-Host "      [!] No candidates found." -ForegroundColor Yellow
            continue
        }

        Write-Host "      -> Found $($UpdateIds.Count) packages. Fetching deep versions..." -NoNewline
        $counter = 0

        foreach ($Id in $UpdateIds) {
            $counter++
            if ($counter % 5 -eq 0) { Write-Host "." -NoNewline }
            
            $DetailsUrl = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$Id"
            try {
                $DetailsPage = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -ErrorAction SilentlyContinue
                if ($DetailsPage.Content -match "id=`"ScopedViewHandler_version`">([^<]+)") {
                    $Version = $matches[1].Trim()
                    $DateInt = Get-RealtekDriverDate -Version $Version
                    
                    if ($Version -like "$Prefix.*" -and $DateInt -gt 0) {
                        $AvailablePackages += [PSCustomObject]@{
                            Prefix  = $Prefix
                            Version = $Version
                            DateInt = $DateInt
                            Id      = $Id
                        }
                    }
                }
            }
            catch {}
        }
        Write-Host " Done."
    }
    
    if (-not $AvailablePackages) {
        Write-Host "   [!] No matching prefixes found within candidate packages." -ForegroundColor Yellow
        continue
    }

    # Group the packages by Prefix and find the best (highest DateInt) for each
    $GroupedPackages = $AvailablePackages | Group-Object Prefix
    
    foreach ($Group in $GroupedPackages) {
        $BestPackage = $Group.Group | Sort-Object DateInt -Descending | Select-Object -First 1
        Write-Host "   -> Prefix $($Group.Name): Selected $($BestPackage.Version) (Update ID: $($BestPackage.Id))" -ForegroundColor Green
        
        $PostData = "[{`"size`":0,`"updateID`":`"$($BestPackage.Id)`",`"uidInfo`":`"$($BestPackage.Id)`"}]"
        $DownloadPage = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method Post -Body @{updateIDs = $PostData } -UseBasicParsing
        
        $CabUrl = [regex]::Match($DownloadPage.Content, 'https://[^''"<]+\.cab').Value
        
        if (-not $CabUrl) {
            Write-Host "      [!] Could not extract .cab URL from payload." -ForegroundColor Red
            continue
        }
        
        $CabFile = Join-Path $TempDir "$($Target.Name)_$($Group.Name).cab"
        $ExtractDir = Join-Path $TempDir "$($Target.Name)"
        
        Write-Host "      -> Downloading raw driver package..."
        Invoke-WebRequest -Uri $CabUrl -OutFile $CabFile -UseBasicParsing
        
        Write-Host "      -> Extracting payload using expand.exe..."
        if (-not (Test-Path $ExtractDir)) { New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null }
        
        Start-Process "expand.exe" -ArgumentList "-F:* `"$CabFile`" `"$ExtractDir`"" -Wait -NoNewWindow -PassThru | Out-Null
        Remove-Item $CabFile -Force
        
        if ($Install) {
            Write-Host "      -> Injecting into Driver Store via pnputil..." -ForegroundColor Green
            pnputil.exe /add-driver "$ExtractDir\*.inf" /install | Out-Null
            Write-Host "      -> Injection complete." -ForegroundColor Green
        }
        else {
            Write-Host "      -> Extracted to: $ExtractDir (Skipping installation)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`nProcess complete." -ForegroundColor Cyan