#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches the latest Intel PROSet/Wireless Wi-Fi drivers from the Microsoft Update Catalog.

    .DESCRIPTION
    Scrapes the Microsoft Update Catalog for Intel Wi-Fi hardware families.
    Intel bundles all supported adapters into unified driver packages, so two
    searches cover everything from AC 9260 through BE200:
      - BE200 package → BE200, AX411, AX211, AX210 (WiFi 7 / 6E)
      - AX200 package → AX200, AX201, AC 9560, AC 9462, AC 9260 (WiFi 6 / AC)

    .NOTES
    SCOPE: These are POST-BOOT CONVENIENCE drivers only. Wi-Fi adapters cannot serve
    iSCSI / network (PXE) boot, so nothing here is boot-critical — it only restores
    wireless connectivity after the OS is already running.
#>

[CmdletBinding()]
param (
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp\Intel_WiFi',

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

# ============================================================
# Helper: retry-with-backoff wrapper around Invoke-WebRequest
# ============================================================
# Defined locally so this script stays independently runnable. The Update Catalog
# throttles aggressively; retry up to 3 times with increasing delay, then re-throw so
# callers can try/catch and skip. NOTE: not available inside ForEach-Object -Parallel
# runspaces (those carry their own inline retry loop).
function Invoke-CatalogRequest {
    param (
        [Parameter(Mandatory)][hashtable]$Params,
        [int]$MaxAttempts = 3
    )
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

$Targets = @(
    @{ 
        Name    = "Intel_WiFi7_Family" 
        Devices = @(
            @{ Prefix = "BE200"; HWID = "VEN_8086&DEV_272B"; FamilyName = "BE200" }
        )
    },
    @{ 
        Name    = "Intel_WiFi6_Family"
        Devices = @(
            @{ Prefix = "AX200"; HWID = "VEN_8086&DEV_2723"; FamilyName = "AX200" }
        )
    }
)

if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

# Acquisition manifest — greppable ACQUIRED:/SKIPPED: lines emitted at the end so a
# throttled/partial parallel run is auditable.
$Manifest = [System.Collections.Generic.List[string]]::new()

foreach ($Target in $Targets) {
    Write-Host "`n=> Investigating Microsoft Update Catalog for $($Target.Name)..." -ForegroundColor Cyan
    
    $AvailablePackages = @()

    foreach ($Device in $Target.Devices) {
        $Prefix = $Device.Prefix
        $HWID = $Device.HWID
        $FamilyName = $Device.FamilyName
        $Query = "$HWID Windows 11"
        Write-Host "   -> Searching specific HWID for Prefix $Prefix ($Query)..."

        # Reset per-iteration so a failed fetch can't silently reuse the PREVIOUS
        # device's page (which would parse the wrong update IDs for this device).
        $SearchPage = $null
        try {
            $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Query))"
            $SearchPage = Invoke-CatalogRequest -Params @{ Uri = $SearchUrl; UseBasicParsing = $true }
        }
        catch {
            Write-Warning "Search request failed for $Prefix ($Query): $_"
            $Manifest.Add("SKIPPED: $FamilyName (search request failed)")
            continue
        }

        # LIMITATION: Search.aspx returns only the first 25 relevance-sorted rows; the
        # "newest by date" pick below only sees those 25. Full pagination needs
        # __EVENTTARGET POST-backs (invasive). Parse the "1 - N of M" total and warn if M > 25.
        if ($SearchPage.Content -match '(\d+)\s*-\s*(\d+)\s+of\s+(\d+)') {
            $totalResults = [int]$matches[3]
            if ($totalResults -gt 25) {
                Write-Warning "Catalog reports $totalResults results for '$Query' but only the first 25 are parsed (pagination not implemented)."
            }
        }

        $UpdateIds = [regex]::Matches($SearchPage.Content, "goToDetails\(['\`"]([a-f0-9\-]+)['\`"]\)") |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique

        if (-not $UpdateIds) {
            Write-Host "      [!] No candidates found." -ForegroundColor Yellow
            $Manifest.Add("SKIPPED: $FamilyName (no catalog candidates)")
            continue
        }

        Write-Host "      -> Found $($UpdateIds.Count) packages. Fetching deep versions..." -NoNewline

        $DetailResults = $UpdateIds | ForEach-Object -Parallel {
            $Id = $_
            $DetailsUrl = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$Id"
            try {
                # Inline retry-with-backoff (the script-scope helper is not visible here).
                $DetailsPage = $null
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    try { $DetailsPage = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing; break }
                    catch { if ($attempt -ge 3) { throw } else { Start-Sleep -Seconds ($attempt * 2) } }
                }
                $DateString = if ($DetailsPage.Content -match 'id="ScopedViewHandler_versionDate">([^<]+)') { $matches[1].Trim() }
                $Version = if ($DetailsPage.Content -match 'id="ScopedViewHandler_version">([^<]+)') { $matches[1].Trim() }

                if ($Version -and $DateString) {
                    $DateObj = [datetime]::Parse($DateString)
                    $Arch = if ($DetailsPage.Content -match "ARM64") { "ARM64" }
                            elseif ($DetailsPage.Content -match "AMD64|x64|amd64") { "AMD64" }
                            else { "x86" }
                    [PSCustomObject]@{
                        Version = $Version
                        DateObj = $DateObj
                        Id      = $Id
                        Arch    = $Arch
                    }
                }
            }
            catch {
                Write-Warning "Detail fetch/parse failed for update $Id : $($_.Exception.Message)"
            }
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
        $Manifest.Add("SKIPPED: $($Target.Name) (no packages matched accepted architectures)")
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
        
        $DownloadPage = $null
        $PostData = "[{`"size`":0,`"updateID`":`"$($BestPackage.Id)`",`"uidInfo`":`"$($BestPackage.Id)`"}]"
        try {
            $DownloadPage = Invoke-CatalogRequest -Params @{ Uri = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"; Method = 'Post'; Body = @{updateIDs = $PostData }; UseBasicParsing = $true }
        }
        catch {
            Write-Warning "Download dialog request failed for $FamilyName [$Arch]: $_"
            $Manifest.Add("SKIPPED: $FamilyName [$Arch] (download dialog failed)")
            continue
        }

        $CabUrl = [regex]::Match($DownloadPage.Content, 'https://[^''\\"<]+\.cab').Value

        if (-not $CabUrl) {
            Write-Host "      [!] Could not extract .cab URL from payload." -ForegroundColor Red
            $Manifest.Add("SKIPPED: $FamilyName [$Arch] (no .cab URL in payload)")
            continue
        }

        $CabFile = Join-Path $DownloadPath "$($Target.Name)_$($Prefix)_$($Arch).cab"
        $ExtractDir = Join-Path $DownloadPath "$($Target.Name)\$FamilyName\$Arch"

        Write-Host "      -> Downloading raw $Arch driver package..."
        try {
            Invoke-CatalogRequest -Params @{ Uri = $CabUrl; OutFile = $CabFile; UseBasicParsing = $true } | Out-Null
        }
        catch {
            Write-Warning "CAB download failed for $FamilyName [$Arch]: $_"
            $Manifest.Add("SKIPPED: $FamilyName [$Arch] (download failed)")
            continue
        }

        # AUTHENTICITY: verify the publisher's Authenticode signature and SKIP (do not
        # extract/inject) anything that is not 'Valid', rather than silently trusting it.
        $sig = Get-AuthenticodeSignature -FilePath $CabFile
        if ($sig.Status -ne 'Valid') {
            Write-Warning "Authenticode signature for $FamilyName [$Arch] CAB is '$($sig.Status)' (not Valid) — skipping extraction/injection."
            $Manifest.Add("SKIPPED: $FamilyName [$Arch] (signature $($sig.Status))")
            Remove-Item $CabFile -Force -ErrorAction SilentlyContinue
            continue
        }

        Write-Host "      -> Extracting payload using expand.exe..."
        if (-not (Test-Path $ExtractDir)) { New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null }

        # Capture expand.exe's exit code. On failure KEEP the source CAB for retry/inspection.
        $expandProc = Start-Process "expand.exe" -ArgumentList "-F:* `"$CabFile`" `"$ExtractDir`"" -NoNewWindow -PassThru
        $expandProc.WaitForExit()
        if ($expandProc.ExitCode -ne 0) {
            Write-Warning "expand.exe exited with code $($expandProc.ExitCode) for $FamilyName [$Arch] — keeping source CAB '$CabFile' for retry/inspection."
            $Manifest.Add("SKIPPED: $FamilyName [$Arch] (expand.exe exit $($expandProc.ExitCode))")
            continue
        }
        Remove-Item $CabFile -Force

        # Manifest: confirm an actual .inf + .sys landed (an empty/partial extract is a skip).
        $infCount = @(Get-ChildItem -Path $ExtractDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
        $sysCount = @(Get-ChildItem -Path $ExtractDir -Recurse -Filter *.sys -ErrorAction SilentlyContinue).Count
        if ($infCount -gt 0 -and $sysCount -gt 0) {
            $Manifest.Add("ACQUIRED: $FamilyName [$Arch]")
        }
        else {
            $Manifest.Add("SKIPPED: $FamilyName [$Arch] (no .inf/.sys after extract)")
        }

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

# ============================================================
# Acquisition manifest (greppable)
# ============================================================
Write-Host "`n=> Acquisition manifest:" -ForegroundColor Cyan
if ($Manifest.Count -eq 0) {
    Write-Host "   (no device families processed)" -ForegroundColor DarkGray
}
else {
    foreach ($line in $Manifest) {
        if ($line -like 'ACQUIRED:*') { Write-Host "   $line" -ForegroundColor Green }
        else { Write-Host "   $line" -ForegroundColor Yellow }
    }
}

Write-Host "`nProcess complete." -ForegroundColor Cyan
