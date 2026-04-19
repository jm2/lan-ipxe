<#
    .SYNOPSIS
    Fetches the latest Intel PROSet/Wireless Wi-Fi drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Scrapes the Microsoft Update Catalog for specific Intel Wi-Fi hardware families
    (e.g., Wi-Fi 7 BE200, Wi-Fi 6E AX210, AX200) to download targeted CAB packages
    ensuring a clean, offline-ready set of INFs for DISM injection.
#>

[CmdletBinding()]
param (
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp\Intel_WiFi'
)

if ($Install -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "The -Install flag requires Administrator privileges. Please run PowerShell as Administrator."
    return
}

$Targets = @(
    @{ 
        Name    = "Intel_WiFi7_Family" 
        Devices = @(
            @{ Prefix = "BE200"; HWID = "VEN_8086&DEV_272B"; FamilyName = "BE200" }
        )
    },
    @{ 
        Name    = "Intel_WiFi6E_Family"
        Devices = @(
            @{ Prefix = "AX210"; HWID = "VEN_8086&DEV_2725"; FamilyName = "AX210" }
        )
    },
    @{ 
        Name    = "Intel_WiFi6_Family"
        Devices = @(
            @{ Prefix = "AX200"; HWID = "VEN_8086&DEV_2723"; FamilyName = "AX200" }
        )
    },
    @{ 
        Name    = "Intel_AC_Family"
        Devices = @(
            @{ Prefix = "AC9260"; HWID = "VEN_8086&DEV_2526"; FamilyName = "AC9260" }
        )
    }
)

if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

foreach ($Target in $Targets) {
    Write-Host "`n=> Investigating Microsoft Update Catalog for $($Target.Name)..." -ForegroundColor Cyan
    
    $AvailablePackages = @()

    foreach ($Device in $Target.Devices) {
        $Prefix = $Device.Prefix
        $HWID = $Device.HWID
        $FamilyName = $Device.FamilyName
        $Query = "$HWID Windows 11"
        Write-Host "   -> Searching specific HWID for Prefix $Prefix ($Query)..."
        
        $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Query))"
        $SearchPage = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing
        
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
                $DateString = if ($DetailsPage.Content -match "id=`"ScopedViewHandler_versionDate`">([^<]+)") { $matches[1].Trim() }
                $Version = if ($DetailsPage.Content -match "id=`"ScopedViewHandler_version`">([^<]+)") { $matches[1].Trim() }
                
                if ($Version -and $DateString) {
                    try {
                        $DateObj = [datetime]::Parse($DateString)
                        $Arch = if ($DetailsPage.Content -match "ARM64") { "ARM64" } elseif ($DetailsPage.Content -match "AMD64") { "AMD64" } else { "x86" }
                        $AvailablePackages += [PSCustomObject]@{
                            Prefix     = $Prefix
                            FamilyName = $FamilyName
                            Version    = $Version
                            DateObj    = $DateObj
                            Id         = $Id
                            Arch       = $Arch
                        }
                    }
                    catch {}
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

    $GroupedPackages = $AvailablePackages | Group-Object Prefix, Arch
    
    foreach ($Group in $GroupedPackages) {
        $FirstObj = $Group.Group[0]
        $Prefix = $FirstObj.Prefix
        $Arch = $FirstObj.Arch
        $FamilyName = $FirstObj.FamilyName

        $BestPackage = $Group.Group | Sort-Object DateObj -Descending | Select-Object -First 1
        Write-Host "   -> Prefix $($Prefix) [$Arch]: Selected $($BestPackage.Version) (Update ID: $($BestPackage.Id))" -ForegroundColor Green
        
        $PostData = "[{`"size`":0,`"updateID`":`"$($BestPackage.Id)`",`"uidInfo`":`"$($BestPackage.Id)`"}]"
        $DownloadPage = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method Post -Body @{updateIDs = $PostData } -UseBasicParsing
        
        $CabUrl = [regex]::Match($DownloadPage.Content, 'https://[^''"<]+\.cab').Value
        
        if (-not $CabUrl) {
            Write-Host "      [!] Could not extract .cab URL from payload." -ForegroundColor Red
            continue
        }
        
        $CabFile = Join-Path $DownloadPath "$($Target.Name)_$($Prefix)_$($Arch).cab"
        $ExtractDir = Join-Path $DownloadPath "$($Target.Name)\$FamilyName\$Arch"
        
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
