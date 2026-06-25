#Requires -Version 7.0
<#
    CatalogScrape.psm1 — shared engine for the Microsoft Update Catalog driver scrapers.

    Replaces ~120 lines of boilerplate that were copy-pasted (and had drifted) across the
    six Get-*Drivers.ps1 scripts. Each vendor is now a thin shim that loads a per-vendor
    .psd1 device table and calls Invoke-DriverScrape.

    Selection policy is "absolute newest" (per project decision): highest parsed [version]
    wins, with catalog date as a tiebreak and any PreferredBranches as a final tiebreak.
    This single rule fixes the prior date-vs-version divergence (Intel re-release picking a
    lower build, Realtek USB picking a stale-dated older build, MediaTek preferred-branch
    filtering out the newer 26.30 branch).

    Pure helpers (parsing/version/date/selection) are factored out and unit-tested on any OS
    via catalogscrape/Test-CatalogScrape.ps1; the Windows-only I/O (Authenticode/expand/
    pnputil) mirrors the original scripts verbatim.

    NOTE: the per-update detail fetch uses ForEach-Object -Parallel. Module functions are NOT
    visible inside -Parallel runspaces, so that block only does the network fetch (built-in
    cmdlets + $using:) and returns raw HTML; parsing happens afterward in module scope via the
    single ConvertFrom-CsDetailHtml function (no duplicated parse logic).
#>

# ============================================================
# Pure helpers (OS-agnostic, network-free, unit-tested)
# ============================================================

function Get-CsAcceptedArch {
    param([string]$Architecture)
    $arr = switch ($Architecture) {
        'x64'   { @('AMD64') }
        'arm64' { @('ARM64') }
        'all'   { @('AMD64', 'ARM64') }
        default { @('AMD64') }
    }
    return , $arr
}

function Get-CsCatalogTotal {
    # Parse the "N - M of TOTAL" row counter; -1 when absent.
    param([string]$Content)
    if ($Content -match '(\d+)\s*-\s*(\d+)\s+of\s+(\d+)') { return [int]$matches[3] }
    return -1
}

function Get-CsCatalogUpdateId {
    # Extract the update GUIDs from goToDetails('<guid>'). The JS function definition
    # goToDetails(updateID) carries no quotes so it cannot match; the trailing GUID-shape
    # filter is belt-and-suspenders.
    param([string]$Content)
    $ids = [regex]::Matches($Content, "goToDetails\(['""]([a-f0-9\-]+)['""]\)") |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique
    return @($ids | Where-Object { $_ -match '^[a-f0-9]{8}-' })
}

function Expand-CsQuery {
    # Dual-query union: HWID-shaped queries (VEN_xxxx&DEV_xxxx / VID_xxxx&PID_xxxx) are issued
    # in BOTH the bare and the "+ Windows 11" form, to sample two independent relevance windows.
    # The catalog returns only the first 25 relevance-sorted rows per query and REJECTS scripted
    # sort/pagination postbacks (verified: both MSCatalog and a hand-rolled VIEWSTATE replay get
    # an error page), so two windows widen coverage without depending on either form being the
    # "right" one — update IDs are deduped across the union and highest [version] wins. Name /
    # phrase queries (marketing names like "Killer AX500", "Marvell FastLinQ") are used as-is;
    # appending an OS token to a name distorts or zeroes the search.
    param([string]$Query)
    if ($Query -match '^(VEN|VID)_[0-9A-Fa-f]+&(DEV|PID)_[0-9A-Fa-f]+$') {
        return @($Query, "$Query Windows 11")
    }
    return , @($Query)
}

function ConvertTo-CsVersion {
    # Tolerant version parse: strip a leading v, take up to 4 leading numeric groups,
    # default the missing components to 0. Returns $null only when there is no leading
    # number at all (caller logs + drops). Replaces the bare [version] cast that silently
    # discarded any non-strictly-dotted string inside an empty catch{}.
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $m = [regex]::Match($Raw.Trim(), '^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    # The [int] cast is inside the try so an out-of-Int32-range component returns $null
    # (per contract) instead of throwing and aborting the scrape.
    try {
        $parts = for ($i = 1; $i -le 4; $i++) {
            if ($m.Groups[$i].Success) { [int]$m.Groups[$i].Value } else { 0 }
        }
        return [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
    }
    catch { return $null }
}

function ConvertTo-CsDate {
    # Locale-independent date parse (catalog serves US M/d/yyyy). Replaces
    # [datetime]::Parse which is current-culture and can scramble the sort on non-US hosts.
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    # Must be [string[]] or overload resolution picks the single-format ParseExact and fails.
    [string[]]$fmts = @('M/d/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd', 'M/d/yyyy h:mm:ss tt')
    try {
        return [datetime]::ParseExact($Raw.Trim(), $fmts, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None)
    }
    catch { return $null }
}

function ConvertFrom-CsDetailHtml {
    # Parse one ScopedViewInline detail page. Returns $null unless BOTH version and
    # versionDate are present (matches the original contract). Version is returned RAW;
    # the orchestrator converts it via ConvertTo-CsVersion. Arch heuristic preserved
    # verbatim from the originals (known-good in practice; the catalog exposes no clean
    # single-token Architecture value).
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Id
    )
    $title = if ($Content -match 'id="ScopedViewHandler_titleText">([^<]+)') { $matches[1].Trim() } else { $null }
    $verRaw = if ($Content -match 'id="ScopedViewHandler_version">([^<]+)') { $matches[1].Trim() } else { $null }
    $dateRaw = if ($Content -match 'id="ScopedViewHandler_versionDate">([^<]+)') { $matches[1].Trim() } else { $null }
    if (-not $verRaw -or -not $dateRaw) { return $null }
    $dateObj = ConvertTo-CsDate $dateRaw
    if (-not $dateObj) { $dateObj = [datetime]::MinValue }
    $arch = if ($Content -match 'ARM64') { 'ARM64' }
    elseif ($Content -match 'AMD64|x64|amd64') { 'AMD64' }
    else { 'x86' }
    return [pscustomobject]@{
        Id      = $Id
        Title   = $title
        Version = $verRaw
        DateObj = $dateObj
        Arch    = $arch
    }
}

function Test-CsTitleExcluded {
    # True if Title matches any exclude pattern (NDIS / bluetooth|uart for WiFi combos).
    param([string]$Title, [string[]]$Patterns)
    if (-not $Patterns) { return $false }
    if ([string]::IsNullOrEmpty($Title)) { return $false }
    foreach ($p in $Patterns) { if ($Title -match $p) { return $true } }
    return $false
}

function Get-CsBranchRank {
    # Index of the first PreferredBranch the version's major.minor begins with, else MaxValue.
    param([version]$Version, [string[]]$PreferredBranches)
    if (-not $PreferredBranches) { return [int]::MaxValue }
    $v = $Version.ToString()
    for ($i = 0; $i -lt $PreferredBranches.Count; $i++) {
        if ($v.StartsWith("$($PreferredBranches[$i]).")) { return $i }
    }
    return [int]::MaxValue
}

function Select-CsBestPackage {
    # "Absolute newest": highest [version] first, then newest DateObj, then preferred-branch
    # rank as a final tiebreak. Packages must already carry a [version] Version and a DateObj.
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [string[]]$PreferredBranches = @()
    )
    if (-not $Packages -or $Packages.Count -eq 0) { return $null }
    return $Packages | Sort-Object `
        @{ Expression = { $_.Version }; Descending = $true }, `
        @{ Expression = { $_.DateObj }; Descending = $true }, `
        @{ Expression = { Get-CsBranchRank -Version $_.Version -PreferredBranches $PreferredBranches }; Descending = $false } |
        Select-Object -First 1
}

# ============================================================
# Network helpers
# ============================================================

function Test-CsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Invoke-CsRequest {
    # Retry-with-backoff wrapper. Adds a bounded -TimeoutSec (was absent everywhere — a
    # stalled connection used to hang the whole run) and a browser User-Agent.
    param(
        [Parameter(Mandatory)][hashtable]$Params,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSec = 60
    )
    if (-not $Params.ContainsKey('TimeoutSec')) { $Params['TimeoutSec'] = $TimeoutSec }
    if (-not $Params.ContainsKey('UserAgent')) { $Params['UserAgent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) lan-ipxe-catalog-scrape' }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return Invoke-WebRequest @Params }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Get-CsDetail {
    # Parallel detail-page FETCH only (self-contained -Parallel block: built-ins + $using
    # plus an inline retry, because module functions are invisible in the runspace). Parsing
    # is done afterward in module scope so the regexes live in exactly one place.
    param(
        [string[]]$UpdateIds,
        [int]$ThrottleLimit = 6,
        [int]$TimeoutSec = 60
    )
    if (-not $UpdateIds) { return @() }
    $raw = $UpdateIds | ForEach-Object -Parallel {
        $ProgressPreference = 'SilentlyContinue'  # parallel runspaces start fresh; suppress progress bars
        $Id = $_
        $url = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$Id"
        $to = $using:TimeoutSec
        $content = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $content = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $to -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) lan-ipxe-catalog-scrape').Content
                break
            }
            catch {
                if ($attempt -ge 3) { Write-Warning "Detail fetch failed for update $Id : $($_.Exception.Message)" }
                else { Start-Sleep -Seconds ($attempt * 2) }
            }
        }
        [pscustomobject]@{ Id = $Id; Content = $content }
    } -ThrottleLimit $ThrottleLimit

    $out = foreach ($r in $raw) {
        if (-not $r.Content) { continue }
        ConvertFrom-CsDetailHtml -Content $r.Content -Id $r.Id
    }
    return @($out)
}

# ============================================================
# Orchestrator
# ============================================================

function Invoke-DriverScrape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$Install,
        [Parameter(Mandatory)][string]$DownloadPath,
        [ValidateSet('x64', 'arm64', 'all')][string]$Architecture = 'x64',
        [int]$MetadataTimeoutSec = 60,
        [int]$DownloadTimeoutSec = 600,
        [int]$ThrottleLimit = 6
    )

    $ProgressPreference = 'SilentlyContinue'
    $AcceptedArchs = Get-CsAcceptedArch $Architecture

    if ($Install -and -not (Test-CsAdmin)) {
        Write-Error "The -Install flag requires Administrator privileges. Please run PowerShell as Administrator."
        return
    }

    if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }
    $DownloadPath = [System.IO.Path]::GetFullPath($DownloadPath)
    # Namespace by vendor so concurrent scrapers sharing one root path never collide on
    # CAB filenames or extract dirs (build_win11pxe.ps1 hands every scraper the same root).
    $vendorRoot = Join-Path $DownloadPath $Config.VendorKey
    if (-not (Test-Path $vendorRoot)) { New-Item -ItemType Directory -Path $vendorRoot -Force | Out-Null }

    $Manifest = [System.Collections.Generic.List[string]]::new()

    foreach ($Target in $Config.Targets) {
        Write-Host "`n=> Investigating Microsoft Update Catalog for $($Target.Name)..." -ForegroundColor Cyan
        $AvailablePackages = @()

        foreach ($Device in $Target.Devices) {
            $deviceKey = $Device.Key
            $label = $Device.Label
            $titleExclude = if ($Device.ContainsKey('TitleExclude')) { @($Device.TitleExclude) } else { @() }
            $seenIds = [System.Collections.Generic.HashSet[string]]::new()

            # Expand each base query into its dual-query-union variants, then dedup.
            $queries = @()
            foreach ($baseQuery in @($Device.Queries)) { $queries += Expand-CsQuery $baseQuery }
            $queries = @($queries | Select-Object -Unique)

            foreach ($query in $queries) {
                Write-Host "   -> Searching $label ($query)..."

                $searchPage = $null
                try {
                    $searchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($query))"
                    $searchPage = Invoke-CsRequest -Params @{ Uri = $searchUrl; UseBasicParsing = $true } -TimeoutSec $MetadataTimeoutSec
                }
                catch {
                    Write-Warning "Search request failed for $label ($query): $_"
                    continue
                }

                $total = Get-CsCatalogTotal $searchPage.Content
                if ($total -gt 25) {
                    Write-Warning "Catalog reports $total results for '$query' but only the first 25 are parsed (pagination not implemented)."
                }

                $updateIds = Get-CsCatalogUpdateId $searchPage.Content
                if (-not $updateIds) {
                    Write-Host "      [!] No candidates for this query." -ForegroundColor Yellow
                    continue
                }

                Write-Host "      -> $($updateIds.Count) candidates. Fetching detail pages..." -NoNewline
                $details = Get-CsDetail -UpdateIds $updateIds -ThrottleLimit $ThrottleLimit -TimeoutSec $MetadataTimeoutSec
                Write-Host " Done."

                foreach ($d in $details) {
                    if (-not $d) { continue }
                    if ($d.Arch -notin $AcceptedArchs) { continue }
                    if (Test-CsTitleExcluded -Title $d.Title -Patterns $titleExclude) { continue }
                    if (-not $seenIds.Add($d.Id)) { continue }  # dedup across this device's queries

                    $ver = ConvertTo-CsVersion $d.Version
                    if (-not $ver) {
                        Write-Warning "Dropped $label candidate $($d.Id): unparseable version '$($d.Version)'."
                        continue
                    }

                    $AvailablePackages += [pscustomobject]@{
                        Key              = $deviceKey
                        Label            = $label
                        Version          = $ver
                        VersionRaw       = $d.Version
                        DateObj          = $d.DateObj
                        Id               = $d.Id
                        Arch             = $d.Arch
                        Title            = $d.Title
                        PreferredBranches = if ($Device.ContainsKey('PreferredBranches')) { @($Device.PreferredBranches) } else { @() }
                    }
                }
            }
        }

        if (-not $AvailablePackages) {
            Write-Host "   [!] No packages matched accepted architectures." -ForegroundColor Yellow
            $Manifest.Add("SKIPPED: $($Target.Name) (no packages matched accepted architectures)")
            continue
        }

        # Mark devices that yielded nothing so the manifest stays complete.
        $foundKeys = @($AvailablePackages.Key | Select-Object -Unique)
        foreach ($Device in $Target.Devices) {
            if ($Device.Key -notin $foundKeys) {
                $Manifest.Add("SKIPPED: $($Device.Label) (no catalog candidates)")
            }
        }

        $groups = $AvailablePackages | Group-Object Key, Arch
        foreach ($group in $groups) {
            $first = $group.Group[0]
            $deviceKey = $first.Key
            $label = $first.Label
            $arch = $first.Arch
            $best = Select-CsBestPackage -Packages $group.Group -PreferredBranches @($first.PreferredBranches)

            $branchNote = ''
            if ($first.PreferredBranches) {
                $rank = Get-CsBranchRank -Version $best.Version -PreferredBranches @($first.PreferredBranches)
                $branchNote = if ($rank -lt [int]::MaxValue) { " [branch $($first.PreferredBranches[$rank])]" } else { " [highest version]" }
            }
            Write-Host "   -> $label [$arch]: selected v$($best.VersionRaw)$branchNote (Update ID: $($best.Id))" -ForegroundColor Green

            # --- DownloadDialog -> .cab URL ---
            $postData = "[{`"size`":0,`"updateID`":`"$($best.Id)`",`"uidInfo`":`"$($best.Id)`"}]"
            $downloadPage = $null
            try {
                $downloadPage = Invoke-CsRequest -Params @{ Uri = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'; Method = 'Post'; Body = @{ updateIDs = $postData }; UseBasicParsing = $true } -TimeoutSec $MetadataTimeoutSec
            }
            catch {
                Write-Warning "Download dialog request failed for $label [$arch]: $_"
                $Manifest.Add("SKIPPED: $label [$arch] (download dialog failed)")
                continue
            }

            $cabUrl = [regex]::Match($downloadPage.Content, 'https://[^''"<]+\.cab').Value
            if (-not $cabUrl) {
                Write-Host "      [!] Could not extract .cab URL from payload." -ForegroundColor Red
                $Manifest.Add("SKIPPED: $label [$arch] (no .cab URL in payload)")
                continue
            }

            $cabFile = Join-Path $vendorRoot "$($Target.Name)_$($deviceKey)_$($arch).cab"
            $extractDir = Join-Path $vendorRoot "$($Target.Name)\$deviceKey\$arch"

            Write-Host "      -> Downloading $arch package..."
            try {
                Invoke-CsRequest -Params @{ Uri = $cabUrl; OutFile = $cabFile; UseBasicParsing = $true } -TimeoutSec $DownloadTimeoutSec | Out-Null
            }
            catch {
                Write-Warning "CAB download failed for $label [$arch]: $_"
                $Manifest.Add("SKIPPED: $label [$arch] (download failed)")
                continue
            }

            # AUTHENTICITY: catalog driver CABs carry an embedded WHQL Authenticode signature
            # (verified: PKCS#7 in the cabinet reserve, chains to Microsoft Root CA 2010), so
            # Get-AuthenticodeSignature returns 'Valid'. Fail closed: skip anything not Valid.
            $sig = Get-AuthenticodeSignature -FilePath $cabFile
            if ($sig.Status -ne 'Valid') {
                Write-Warning "Authenticode signature for $label [$arch] CAB is '$($sig.Status)' (not Valid) — skipping extraction/injection."
                $Manifest.Add("SKIPPED: $label [$arch] (signature $($sig.Status))")
                Remove-Item $cabFile -Force -ErrorAction SilentlyContinue
                continue
            }

            Write-Host "      -> Extracting via expand.exe..."
            if (-not (Test-Path $extractDir)) { New-Item -ItemType Directory -Path $extractDir -Force | Out-Null }

            $expandProc = Start-Process 'expand.exe' -ArgumentList "-F:* `"$cabFile`" `"$extractDir`"" -NoNewWindow -PassThru -Wait
            # Non-zero is a failure; a $null ExitCode (rare) is treated as success and caught
            # by the .inf/.sys verification below rather than misflagged as a failure.
            if ($expandProc.ExitCode) {
                Write-Warning "expand.exe exited $($expandProc.ExitCode) for $label [$arch] — keeping CAB '$cabFile' for inspection."
                $Manifest.Add("SKIPPED: $label [$arch] (expand.exe exit $($expandProc.ExitCode))")
                continue
            }
            Remove-Item $cabFile -Force -ErrorAction SilentlyContinue

            $infCount = @(Get-ChildItem -Path $extractDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
            $sysCount = @(Get-ChildItem -Path $extractDir -Recurse -Filter *.sys -ErrorAction SilentlyContinue).Count
            if ($infCount -gt 0 -and $sysCount -gt 0) {
                $Manifest.Add("ACQUIRED: $label [$arch]")
            }
            else {
                # Remove the incomplete extract so a downstream DISM /Add-Driver /Recurse
                # cannot pick up a broken package.
                Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                $Manifest.Add("SKIPPED: $label [$arch] (no .inf/.sys after extract)")
                continue
            }

            if ($Install) {
                $sysArch = $env:PROCESSOR_ARCHITECTURE
                if ($sysArch -eq $arch) {
                    Write-Host "      -> System is $sysArch. Injecting via pnputil (/subdirs)..." -ForegroundColor Green
                    # /subdirs so injection matches the recursive .inf detection above.
                    pnputil.exe /add-driver (Join-Path $extractDir '*.inf') /subdirs /install | Out-Null
                    Write-Host "      -> Injection complete." -ForegroundColor Green
                }
                else {
                    Write-Host "      -> System is $sysArch. Skipping $arch injection." -ForegroundColor DarkGray
                }
            }
            else {
                Write-Host "      -> Extracted to: $extractDir (not installing)" -ForegroundColor DarkGray
            }
        }
    }

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
}

Export-ModuleMember -Function @(
    'Invoke-DriverScrape',
    'Invoke-CsRequest', 'Get-CsDetail',
    'Get-CsAcceptedArch', 'Get-CsCatalogTotal', 'Get-CsCatalogUpdateId', 'Expand-CsQuery',
    'ConvertTo-CsVersion', 'ConvertTo-CsDate', 'ConvertFrom-CsDetailHtml',
    'Test-CsTitleExcluded', 'Get-CsBranchRank', 'Select-CsBestPackage'
)
