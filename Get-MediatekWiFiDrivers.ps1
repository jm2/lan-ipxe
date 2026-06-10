#Requires -Version 7.0
<#
    .SYNOPSIS
    Fetches and optionally installs the absolute latest MediaTek Wi-Fi drivers 
    directly from the Microsoft Update Catalog.

    .DESCRIPTION
    This script queries the Catalog for MediaTek Wi-Fi adapters (MT7921, MT7921K, MT7922, MT7925, MT7927),
    pulls the detailed version for every package, and prioritizes packages using 
    standard Semantic Versioning or simply taking the global highest version available.
    Native ARM64 support is explicitly accounted for automatically, as MediaTek is 
    heavily featured in modern Copilot+ and Surface devices.

    .EXAMPLE
    .\Get-MediatekWiFiDrivers.ps1
    Downloads and extracts the newest drivers to C:\Temp\MediaTek_WiFi without installing.

    .EXAMPLE
    .\Get-MediatekWiFiDrivers.ps1 -Install
    Downloads, extracts, installs the drivers to the Driver Store, and cleans up the CABs.

    .NOTES
    SCOPE: These are POST-BOOT CONVENIENCE drivers only. Wi-Fi adapters cannot serve
    iSCSI / network (PXE) boot, so nothing here is boot-critical — it only restores
    wireless connectivity after the OS is already running.
#>

[CmdletBinding()]
param (
    [switch]$Install,
    [string]$DownloadPath = 'C:\Temp\MediaTek_WiFi',

    [ValidateSet('x64','arm64','all')]
    [string]$Architecture = 'x64'
)

$AcceptedArchs = switch ($Architecture) {
    'x64'   { @('AMD64') }
    'arm64' { @('ARM64') }
    'all'   { @('AMD64','ARM64') }
}

# Dynamic Admin Check
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
        Name    = "MediaTek_WiFi_Family" 
        Devices = @(
            @{ 
                ModelId           = "7961"
                ModelName         = "MT7921_Filogic330"
                Queries           = @("VEN_14C3&DEV_7961", "MT7921")
                PreferredBranches = @("3.5")
            },
            @{ 
                ModelId           = "0608"
                ModelName         = "MT7921K_RZ608"
                Queries           = @("VEN_14C3&DEV_0608", "RZ608")
                PreferredBranches = @("3.5")
            },
            @{ 
                ModelId           = "0616"
                ModelName         = "MT7922_RZ616"
                Queries           = @("VEN_14C3&DEV_0616", "MT7922", "RZ616")
                PreferredBranches = @("3.5")
            },
            @{ 
                ModelId           = "7925"
                ModelName         = "MT7925_Filogic380"
                Queries           = @("VEN_14C3&DEV_7925", "MT7925")
                PreferredBranches = @("25.30", "5.7")
            },
            @{ 
                ModelId           = "7927"
                ModelName         = "MT7927_Filogic380High"
                Queries           = @("VEN_14C3&DEV_7927", "MT7927")
                PreferredBranches = @("25.30", "5.7")
            }
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
        $ModelId = $Device.ModelId

        foreach ($Query in $Device.Queries) {
            Write-Host "   -> Searching for ModelId $ModelId ($Query)..."

            # Reset per-iteration so a failed fetch can't silently reuse the PREVIOUS
            # query's page (which would parse the wrong update IDs for this query).
            $SearchPage = $null
            try {
                $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($Query))"
                $SearchPage = Invoke-CatalogRequest -Params @{ Uri = $SearchUrl; UseBasicParsing = $true }
            }
            catch {
                Write-Warning "Search request failed for $($Device.ModelName) ($Query): $_"
                $Manifest.Add("SKIPPED: $($Device.ModelName) (search request failed: $Query)")
                continue
            }

            # LIMITATION: Search.aspx returns only the first 25 relevance-sorted rows; the
            # "highest version" pick below only sees those 25. Full pagination needs
            # __EVENTTARGET POST-backs (invasive). Parse the "1 - N of M" total and warn if M > 25.
            if ($SearchPage.Content -match '(\d+)\s*-\s*(\d+)\s+of\s+(\d+)') {
                $totalResults = [int]$matches[3]
                if ($totalResults -gt 25) {
                    Write-Warning "Catalog reports $totalResults results for '$Query' but only the first 25 are parsed (pagination not implemented)."
                }
            }

            # Extract all update IDs from the search results table
            $UpdateIds = [regex]::Matches($SearchPage.Content, "goToDetails\(['""]([a-f0-9\-]+)['""]\)") |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique

            if (-not $UpdateIds) {
                Write-Host "      [!] No candidates found for this query." -ForegroundColor Yellow
                continue
            }

            Write-Host "      -> Found $($UpdateIds.Count) packages for query '$Query'. Fetching deep versions..." -NoNewline

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
                    $Title = if ($DetailsPage.Content -match 'id="ScopedViewHandler_titleText">([^<]+)') { $matches[1].Trim() }

                    if ($Version -and $DateString) {
                        $DateObj = [datetime]::Parse($DateString)
                        $Arch = if ($DetailsPage.Content -match "ARM64") { "ARM64" } elseif ($DetailsPage.Content -match "AMD64|x64|amd64") { "AMD64" } else { "x86" }
                        [PSCustomObject]@{
                            Version = $Version
                            DateObj = $DateObj
                            Id      = $Id
                            Arch    = $Arch
                            Title   = $Title
                        }
                    }
                }
                catch {
                    Write-Warning "Detail fetch/parse failed for update $Id : $($_.Exception.Message)"
                }
            } -ThrottleLimit 8

            Write-Host " Done."

            foreach ($result in $DetailResults) {
                # The marketing-name queries (MT7921, RZ616, ...) also return the combo-chip's
                # Bluetooth/UART driver entries, which would otherwise pass the lone -notmatch
                # 'NDIS' filter. Exclude Title 'bluetooth'/'uart' so only the Wi-Fi NIC package
                # is selected.
                if ($result -and $result.Arch -in $AcceptedArchs -and $result.Title -notmatch "NDIS" -and $result.Title -notmatch '(?i)bluetooth|uart') {
                    try {
                        $AvailablePackages += [PSCustomObject]@{
                            ModelId           = $ModelId
                            ModelName         = $Device.ModelName
                            Version           = [version]$result.Version
                            DateObj           = $result.DateObj
                            Id                = $result.Id
                            Title             = $result.Title
                            PreferredBranches = $Device.PreferredBranches
                            Arch              = $result.Arch
                        }
                    }
                    catch {}
                }
            }
        }
    }
    
    if (-not $AvailablePackages) {
        Write-Host "   [!] No matching ModelIds found within candidate packages." -ForegroundColor Yellow
        $Manifest.Add("SKIPPED: $($Target.Name) (no packages matched accepted architectures)")
        continue
    }

    # Record models that yielded no usable Wi-Fi candidate so the manifest stays complete
    # (a model is only marked here if NONE of its queries produced a package).
    $FoundModelIds = @($AvailablePackages.ModelId | Select-Object -Unique)
    foreach ($Device in $Target.Devices) {
        if ($Device.ModelId -notin $FoundModelIds) {
            $Manifest.Add("SKIPPED: $($Device.ModelName) (no Wi-Fi catalog candidates)")
        }
    }

    # Group all valid candidate packages into their correct respective HWModelId families and Architecture, and find the freshest.
    $GroupedPackages = $AvailablePackages | Group-Object ModelId, Arch
    
    foreach ($Group in $GroupedPackages) {
        $FirstObj = $Group.Group[0]
        $ModelId = $FirstObj.ModelId
        $Arch = $FirstObj.Arch
        $ModelName = $FirstObj.ModelName
        
        $BestPackage = $null
        $TargetBranches = $FirstObj.PreferredBranches
        
        if ($TargetBranches) {
            foreach ($Branch in $TargetBranches) {
                $BranchMatches = $Group.Group | Where-Object { $_.Version.ToString().StartsWith("$Branch.") }
                if ($BranchMatches.Count -gt 0) {
                    $BestPackage = $BranchMatches | Sort-Object Version -Descending | Select-Object -First 1
                    Write-Host "   -> ModelId $($ModelId) [$Arch]: Selected v$($BestPackage.Version) [Preferred Branch: $Branch] (Update ID: $($BestPackage.Id))" -ForegroundColor Green
                    break
                }
            }
            if (-not $BestPackage) {
                $BestPackage = $Group.Group | Sort-Object Version -Descending | Select-Object -First 1
                Write-Host "   -> ModelId $($ModelId) [$Arch]: Selected v$($BestPackage.Version) [Global Highest] (Update ID: $($BestPackage.Id))" -ForegroundColor Green
            }
        }
        else {
            $BestPackage = $Group.Group | Sort-Object Version -Descending | Select-Object -First 1
            Write-Host "   -> ModelId $($ModelId) [$Arch]: Selected v$($BestPackage.Version) [Global Highest] (Update ID: $($BestPackage.Id))" -ForegroundColor Green
        }
        
        $DownloadPage = $null
        $PostData = "[{`"size`":0,`"updateID`":`"$($BestPackage.Id)`",`"uidInfo`":`"$($BestPackage.Id)`"}]"
        try {
            $DownloadPage = Invoke-CatalogRequest -Params @{ Uri = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"; Method = 'Post'; Body = @{updateIDs = $PostData }; UseBasicParsing = $true }
        }
        catch {
            Write-Warning "Download dialog request failed for $ModelName [$Arch]: $_"
            $Manifest.Add("SKIPPED: $ModelName [$Arch] (download dialog failed)")
            continue
        }

        $CabUrl = [regex]::Match($DownloadPage.Content, 'https://[^''"<]+\.cab').Value

        if (-not $CabUrl) {
            Write-Host "      [!] Could not extract .cab URL from payload." -ForegroundColor Red
            $Manifest.Add("SKIPPED: $ModelName [$Arch] (no .cab URL in payload)")
            continue
        }

        $CabFile = Join-Path $DownloadPath "$($Target.Name)_$($ModelId)_$($Arch).cab"
        $ExtractDir = Join-Path $DownloadPath "$($Target.Name)\$ModelName\$Arch"

        Write-Host "      -> Downloading raw $Arch driver package..."
        try {
            Invoke-CatalogRequest -Params @{ Uri = $CabUrl; OutFile = $CabFile; UseBasicParsing = $true } | Out-Null
        }
        catch {
            Write-Warning "CAB download failed for $ModelName [$Arch]: $_"
            $Manifest.Add("SKIPPED: $ModelName [$Arch] (download failed)")
            continue
        }

        # AUTHENTICITY: verify the publisher's Authenticode signature and SKIP (do not
        # extract/inject) anything that is not 'Valid', rather than silently trusting it.
        $sig = Get-AuthenticodeSignature -FilePath $CabFile
        if ($sig.Status -ne 'Valid') {
            Write-Warning "Authenticode signature for $ModelName [$Arch] CAB is '$($sig.Status)' (not Valid) — skipping extraction/injection."
            $Manifest.Add("SKIPPED: $ModelName [$Arch] (signature $($sig.Status))")
            Remove-Item $CabFile -Force -ErrorAction SilentlyContinue
            continue
        }

        Write-Host "      -> Extracting payload using expand.exe..."
        if (-not (Test-Path $ExtractDir)) { New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null }

        # Capture expand.exe's exit code. On failure KEEP the source CAB for retry/inspection.
        $expandProc = Start-Process "expand.exe" -ArgumentList "-F:* `"$CabFile`" `"$ExtractDir`"" -NoNewWindow -PassThru
        $expandProc.WaitForExit()
        if ($expandProc.ExitCode -ne 0) {
            Write-Warning "expand.exe exited with code $($expandProc.ExitCode) for $ModelName [$Arch] — keeping source CAB '$CabFile' for retry/inspection."
            $Manifest.Add("SKIPPED: $ModelName [$Arch] (expand.exe exit $($expandProc.ExitCode))")
            continue
        }
        Remove-Item $CabFile -Force

        # Manifest: confirm an actual .inf + .sys landed (an empty/partial extract is a skip).
        $infCount = @(Get-ChildItem -Path $ExtractDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
        $sysCount = @(Get-ChildItem -Path $ExtractDir -Recurse -Filter *.sys -ErrorAction SilentlyContinue).Count
        if ($infCount -gt 0 -and $sysCount -gt 0) {
            $Manifest.Add("ACQUIRED: $ModelName [$Arch]")
        }
        else {
            $Manifest.Add("SKIPPED: $ModelName [$Arch] (no .inf/.sys after extract)")
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