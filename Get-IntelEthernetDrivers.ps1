#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Intel Ethernet drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Scrapes the Microsoft Update Catalog for specific Intel Ethernet hardware families
    (e.g., I225-V, I219-V, X540, X550, X710, E810) to download targeted CAB packages
    rather than downloading the monolithic multi-gigabyte Intel ZIP, ensuring a clean,
    offline-ready set of INFs for DISM injection without downloading hundreds of CABs.
#>

[CmdletBinding()]
param (
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp\Intel_Ethernet',

    [ValidateSet('x64','arm64','all')]
    [string]$Architecture = 'x64'
)

$AcceptedArchs = switch ($Architecture) {
    'x64'   { @('AMD64') }
    'arm64' { @('ARM64') }
    'all'   { @('AMD64','ARM64') }
}

if ($Install -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "The -Install flag requires Administrator privileges. Please run PowerShell as Administrator."
    return
}

$Targets = @(
    @{ 
        Name    = "Intel_2.5G_Family" 
        Devices = @(
            @{ Prefix = "I225-V"; HWID = "VEN_8086&DEV_15F3"; FamilyName = "I225" },
            @{ Prefix = "I226-V"; HWID = "VEN_8086&DEV_125C"; FamilyName = "I226" }
        )
    },
    @{ 
        Name    = "Intel_1G_Family"
        Devices = @(
            # Intel's e1d driver is unified: the INF inside any single package covers ALL
            # I219-V/LM generations (DEV_15B8, 15FA, 0DC8, 0D4F, 15D8, 15B3, etc.).
            # Use DEV_15B8 (gen-2, most widely listed on the catalog) as the representative.
            @{ Prefix = "I219-V"; HWID = "VEN_8086&DEV_15B8"; FamilyName = "I219" },
            @{ Prefix = "I210"; HWID = "VEN_8086&DEV_1533"; FamilyName = "I210" }
        )
    },
    @{ 
        Name    = "Intel_10G_Family"
        Devices = @(
            @{ Prefix = "X540"; HWID = "VEN_8086&DEV_1528"; FamilyName = "X540" },
            @{ Prefix = "X550"; HWID = "VEN_8086&DEV_1563"; FamilyName = "X550" },
            @{ Prefix = "X710"; HWID = "VEN_8086&DEV_1572"; FamilyName = "X710" }
        )
    },
    @{ 
        Name    = "Intel_100G_Family"
        Devices = @(
            @{ Prefix = "E810"; HWID = "VEN_8086&DEV_1592"; FamilyName = "E810" }
        )
    },
    @{ 
        Name    = "Intel_AVF_Family"
        Devices = @(
            @{ Prefix = "IAVF"; HWID = "VEN_8086&DEV_1889"; FamilyName = "IAVF" }
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

        # Parallel detail page fetches — ~10x faster than sequential
        $DetailResults = $UpdateIds | ForEach-Object -Parallel {
            $Id = $_
            $DetailsUrl = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$Id"
            try {
                $DetailsPage = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -ErrorAction SilentlyContinue
                $DateString = if ($DetailsPage.Content -match 'id="ScopedViewHandler_versionDate">([^<]+)') { $matches[1].Trim() }
                $Version = if ($DetailsPage.Content -match 'id="ScopedViewHandler_version">([^<]+)') { $matches[1].Trim() }
                
                if ($Version -and $DateString) {
                    $DateObj = [datetime]::Parse($DateString)
                    $Arch = if ($DetailsPage.Content -match "ARM64") { "ARM64" } elseif ($DetailsPage.Content -match "AMD64|x64|amd64") { "AMD64" } else { "x86" }
                    [PSCustomObject]@{
                        Version = $Version
                        DateObj = $DateObj
                        Id      = $Id
                        Arch    = $Arch
                    }
                }
            }
            catch {}
        } -ThrottleLimit 8

        Write-Host " Done."

        foreach ($result in $DetailResults) {
            if ($result -and $result.Arch -in $AcceptedArchs) {
                $AvailablePackages += [PSCustomObject]@{
                    Prefix     = $Prefix
                    FamilyName = $FamilyName
                    Version    = $result.Version
                    DateObj    = $result.DateObj
                    Id         = $result.Id
                    Arch       = $result.Arch
                }
            }
        }
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
        
        $CabUrl = [regex]::Match($DownloadPage.Content, 'https://[^''\"<]+\.cab').Value
        
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
