<#
.SYNOPSIS
Fetches and optionally installs the latest Realtek NetAdapterCx (11.x) drivers for 
RTL8127 (PCIe) and RTL8159 (USB) directly from the Microsoft Update Catalog.

.EXAMPLE
.\Get-RealtekDrivers.ps1
Downloads and extracts the drivers to C:\Temp\Realtek_NetAdapterCx without installing.

.EXAMPLE
.\Get-RealtekDrivers.ps1 -Install
Downloads, extracts, installs the drivers to the Driver Store, and cleans up the CABs.
#>

[CmdletBinding()]
param (
    [switch]$Install
)

# Dynamic Admin Check: Only require elevation if we are actually injecting into the Driver Store
if ($Install -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "The -Install flag requires Administrator privileges. Please run PowerShell as Administrator."
    return
}

$Targets = @(
    @{ Name = "RTL8127_PCIe_Family"; Query = "Realtek 8127 Windows 11" },
    @{ Name = "RTL8159_USB_Family";  Query = "Realtek 8159 Windows 11" }
)

$TempDir = "C:\Temp\Realtek_NetAdapterCx"
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

foreach ($Target in $Targets) {
    Write-Host "`n=> Querying Microsoft Update Catalog for $($Target.Name)..." -ForegroundColor Cyan
    
    $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Target.Query))"
    $SearchPage = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing
    
    $UpdateIds = [regex]::Matches($SearchPage.Content, "goToDetails\('([a-f0-9\-]+)'\)") | 
                 ForEach-Object { $_.Groups[1].Value } | 
                 Select-Object -Unique
    
    if (-not $UpdateIds) {
        Write-Host "   [!] No updates found for $($Target.Name)." -ForegroundColor Yellow
        continue
    }

    $BestUpdateId = $UpdateIds[0] 
    Write-Host "   -> Found Update ID: $BestUpdateId. Fetching secure download links..."
    
    $PostData = "[{`"size`":0,`"updateID`":`"$BestUpdateId`",`"uidInfo`":`"$BestUpdateId`"}]"
    $DownloadPage = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method Post -Body @{updateIDs=$PostData} -UseBasicParsing
    
    $CabUrl = [regex]::Match($DownloadPage.Content, 'https://[^''"<]+\.cab').Value
    
    if (-not $CabUrl) {
        Write-Host "   [!] Could not extract .cab URL from payload." -ForegroundColor Red
        continue
    }
    
    $CabFile = Join-Path $TempDir "$($Target.Name).cab"
    $ExtractDir = Join-Path $TempDir $($Target.Name)
    
    Write-Host "   -> Downloading raw driver package..."
    Invoke-WebRequest -Uri $CabUrl -OutFile $CabFile -UseBasicParsing
    
    Write-Host "   -> Extracting payload using expand.exe..."
    if (-not (Test-Path $ExtractDir)) { New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null }
    
    Start-Process "expand.exe" -ArgumentList "-F:* `"$CabFile`" `"$ExtractDir`"" -Wait -NoNewWindow -PassThru
    
    # Clean up the cab file regardless of install behavior
    Remove-Item $CabFile -Force
    
    if ($Install) {
        Write-Host "   -> Injecting into Driver Store via pnputil..." -ForegroundColor Green
        pnputil.exe /add-driver "$ExtractDir\*.inf" /install | Out-Null
        Write-Host "   -> Injection complete for $($Target.Name)." -ForegroundColor Green
    } else {
        Write-Host "   -> Extracted to: $ExtractDir (Skipping installation)" -ForegroundColor DarkGray
    }
}

Write-Host "`nProcess complete." -ForegroundColor Cyan