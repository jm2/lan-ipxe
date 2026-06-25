#Requires -Version 7.0
# Network-free unit tests for CatalogScrape.psm1 pure logic. Runs on any OS.
# Usage: pwsh -NoProfile -File catalogscrape/Test-CatalogScrape.ps1 [fixtureDir]
param([string]$FixtureDir = '/tmp')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CatalogScrape.psm1') -Force

$script:pass = 0; $script:fail = 0
function Assert([scriptblock]$Test, [string]$Name) {
    $ok = $false
    try { $ok = [bool](& $Test) } catch { $Name += "  [ERR: $($_.Exception.Message)]" }
    if ($ok) { $script:pass++; "  ok   $Name" } else { $script:fail++; "  FAIL $Name" }
}
function Pkg($ver, $date, $branches = @()) {
    [pscustomobject]@{ Version = [version]$ver; DateObj = [datetime]$date; PreferredBranches = $branches; VersionRaw = $ver }
}

'== Get-CsAcceptedArch =='
Assert { ((Get-CsAcceptedArch 'x64') -join ',') -eq 'AMD64' } 'x64 -> AMD64'
Assert { ((Get-CsAcceptedArch 'all') -join ',') -eq 'AMD64,ARM64' } 'all -> AMD64,ARM64'
Assert { ((Get-CsAcceptedArch 'arm64') -join ',') -eq 'ARM64' } 'arm64 -> ARM64'

'== ConvertTo-CsVersion (tolerant) =='
Assert { (ConvertTo-CsVersion '2.1.5.10') -eq [version]'2.1.5.10' } 'plain 4-part'
Assert { (ConvertTo-CsVersion 'v1.2') -eq [version]'1.2.0.0' } 'leading v, pad'
Assert { (ConvertTo-CsVersion '11.19.602.2025') -eq [version]'11.19.602.2025' } 'realtek build'
Assert { (ConvertTo-CsVersion '26.30.3.62') -eq [version]'26.30.3.62' } 'mediatek 26.30'
Assert { (ConvertTo-CsVersion '23.110.0.0 (WHQL)') -eq [version]'23.110.0.0' } 'trailing junk stripped'
Assert { $null -eq (ConvertTo-CsVersion 'garbage') } 'non-numeric -> null'
Assert { $null -eq (ConvertTo-CsVersion '') } 'empty -> null'

'== ConvertTo-CsDate (invariant) =='
Assert { (ConvertTo-CsDate '12/29/2025') -eq [datetime]'2025-12-29' } 'M/d/yyyy'
Assert { (ConvertTo-CsDate '3/30/2018') -eq [datetime]'2018-03-30' } 'single-digit M'
Assert { (ConvertTo-CsDate '5/13/2019 12:00:00 AM') -eq [datetime]'2019-05-13' } 'with time suffix'
Assert { $null -eq (ConvertTo-CsDate 'not a date') } 'invalid -> null'

'== Get-CsCatalogTotal / Get-CsCatalogUpdateId (inline fixture matching live HTML shape) =='
# If real captured fixtures exist in $FixtureDir they are used; otherwise an inline fixture
# that reproduces the exact live markup shape keeps the test self-contained on any machine.
$searchFixture = Join-Path $FixtureDir 'fixture_search_intel.html'
if (Test-Path $searchFixture) {
    $searchHtml = Get-Content $searchFixture -Raw
    $expectedTotal = 307; $expectedIds = 25
}
else {
    $searchHtml = @'
<script>function goToDetails(updateID){ }</script>
<span>1 - 3 of 307</span>
<a onclick='goToDetails("027e8668-e62d-411f-a4a8-7ad2a44d8d09")'>x</a>
<a onclick='goToDetails("9a29952b-926a-42ee-810a-b3aede39f292")'>y</a>
<a onclick='goToDetails("027e8668-e62d-411f-a4a8-7ad2a44d8d09")'>dup</a>
<a onclick='goToDetails("fd636f31-a309-4393-b195-3eba4fe1aedb")'>z</a>
'@
    $expectedTotal = 307; $expectedIds = 3
}
Assert { (Get-CsCatalogTotal $searchHtml) -eq $expectedTotal } "total = $expectedTotal"
$ids = Get-CsCatalogUpdateId $searchHtml
Assert { $ids.Count -eq $expectedIds } "$expectedIds unique GUIDs (got $($ids.Count))"
Assert { $ids -notcontains 'updateID' } 'JS function-def placeholder excluded'
Assert { $ids[0] -match '^[a-f0-9]{8}-[a-f0-9]{4}-' } 'GUID shape'

'== ConvertFrom-CsDetailHtml =='
$detailFixture = Join-Path $FixtureDir 'fixture_detail_intel.html'
$detailHtml = if (Test-Path $detailFixture) { Get-Content $detailFixture -Raw } else { @'
<span id="ScopedViewHandler_titleText">Intel Net Driver Update (2.1.5.10)</span>
<div>Architecture: AMD64</div>
<span id="ScopedViewHandler_version">2.1.5.10</span>
<span id="ScopedViewHandler_versionDate">12/29/2025</span>
'@ }
$d = ConvertFrom-CsDetailHtml -Content $detailHtml -Id 'test-id'
Assert { $null -ne $d } 'parsed non-null'
Assert { $d.Version -eq '2.1.5.10' } "version 2.1.5.10 (got '$($d.Version)')"
Assert { $d.DateObj -eq [datetime]'2025-12-29' } 'versionDate 12/29/2025'
Assert { $d.Arch -eq 'AMD64' } "arch AMD64 (got '$($d.Arch)')"
Assert { $d.Title -like 'Intel Net Driver Update*' } 'title parsed'
Assert { $null -eq (ConvertFrom-CsDetailHtml -Content '<html>no fields</html>' -Id 'x') } 'missing version/date -> null'

'== Test-CsTitleExcluded =='
Assert { Test-CsTitleExcluded 'Qualcomm Bluetooth UART' @('NDIS', '(?i)bluetooth|uart') } 'bluetooth excluded'
Assert { Test-CsTitleExcluded 'Legacy NDIS adapter' @('NDIS') } 'NDIS excluded'
Assert { -not (Test-CsTitleExcluded 'WCN6855 Wi-Fi' @('NDIS', '(?i)bluetooth|uart')) } 'wifi kept'
Assert { -not (Test-CsTitleExcluded 'anything' @()) } 'empty patterns -> kept'

'== Expand-CsQuery (dual-query union for HWID-shaped queries) =='
$exHwid = Expand-CsQuery 'VEN_8086&DEV_1592'
Assert { @($exHwid).Count -eq 2 } 'HWID expands to 2 variants'
Assert { $exHwid -contains 'VEN_8086&DEV_1592' -and $exHwid -contains 'VEN_8086&DEV_1592 Windows 11' } 'HWID -> bare + Windows 11'
$exUsb = Expand-CsQuery 'VID_2ECA&PID_C101'
Assert { (@($exUsb).Count -eq 2) -and ($exUsb -contains 'VID_2ECA&PID_C101 Windows 11') } 'USB VID/PID expands too'
Assert { @(Expand-CsQuery 'Killer AX500').Count -eq 1 } 'marketing name not expanded'
Assert { @(Expand-CsQuery 'Aquantia AQtion')[0] -eq 'Aquantia AQtion' } 'name query passes through bare'
Assert { @(Expand-CsQuery 'BCM57416 RDMA Ethernet').Count -eq 1 } 'phrase query not expanded'

'== Get-CsBranchRank =='
Assert { (Get-CsBranchRank ([version]'26.30.3.62') @('26.30', '25.30', '5.7')) -eq 0 } 'first branch'
Assert { (Get-CsBranchRank ([version]'5.7.0.5659') @('26.30', '25.30', '5.7')) -eq 2 } 'third branch'
Assert { (Get-CsBranchRank ([version]'9.9.9.9') @('26.30')) -eq ([int]::MaxValue) } 'no branch -> max'

'== Select-CsBestPackage (ALWAYS NEWEST = highest version, date tiebreak, branch tiebreak) =='
# MediaTek MT7925: 26.30 must beat the lower 5.7 branch (higher version AND newer date)
$bestMt = Select-CsBestPackage -Packages @((Pkg '5.7.0.5659' '2026-03-06'), (Pkg '26.30.3.62' '2026-04-08')) -PreferredBranches @('26.30', '25.30', '5.7')
Assert { $bestMt.Version -eq [version]'26.30.3.62' } "MediaTek picks 26.30.3.62 (got $($bestMt.Version))"

# Higher version wins DESPITE older catalog date (the core date-vs-version fix). NB: these two
# stale builds are exactly what RTL8157/8159 now floor out via MinVersion (asserted below).
$bestRtl = Select-CsBestPackage -Packages @((Pkg '11.19.602.2025' '2016-03-30'), (Pkg '11.19.20.602' '2018-03-30'))
Assert { $bestRtl.Version -eq [version]'11.19.602.2025' } "version beats older date: picks 11.19.602.2025 over newer-dated 11.19.20.602 (got $($bestRtl.Version))"

# MinVersion floor (RTL8157/8159): the stale 2016/2018 generic driver is below the 1157/1159
# floor, so the device skips it; a real per-chip 115x.x driver clears the floor automatically.
Assert { ([version]'11.19.602.2025') -lt (ConvertTo-CsVersion '1157') } 'MinVersion floor: legacy 11.19.x is below the 1157 floor (8157/8159 skip the stale generic)'
Assert { (ConvertTo-CsVersion '1157.22.113.2026') -ge (ConvertTo-CsVersion '1157') } 'MinVersion floor: a real 1157.x driver clears the floor'
Assert { (ConvertTo-CsVersion '1159') -gt [version]'11.19.20.602' } 'MinVersion floor: 1159 floor sits above the legacy 815A driver'

# Intel I226-V: re-released older version has a NEWER date; highest version must still win
$bestIntel = Select-CsBestPackage -Packages @((Pkg '2.1.5.10' '2025-12-29'), (Pkg '2.1.5.7' '2026-01-19'))
Assert { $bestIntel.Version -eq [version]'2.1.5.10' } "Intel picks 2.1.5.10 over re-released 2.1.5.7 (got $($bestIntel.Version))"

# Equal version+date: branch tiebreak must still return a deterministic, non-null pick
$bestTie = Select-CsBestPackage -Packages @((Pkg '3.0.0.1' '2026-01-01'), (Pkg '3.0.0.1' '2026-01-01')) -PreferredBranches @('3.0')
Assert { $null -ne $bestTie } 'equal-version tiebreak returns a deterministic pick'

'== .psd1 data tables load + schema =='
$expectKeys = @{
    'intel-eth.psd1'  = 10; 'intel-wifi.psd1' = 2; 'marvell.psd1' = 2
    'realtek.psd1'    = 8; 'qualcomm.psd1' = 3; 'mediatek.psd1' = 5; 'broadcom.psd1' = 3
    # GPU graphics tables (catalog-sourced, post-boot convenience — same engine, no Source block)
    'intel-gfx.psd1'  = 1; 'nvidia-gfx.psd1' = 2; 'amd-gfx.psd1' = 5
}
foreach ($f in $expectKeys.Keys) {
    $cfg = Import-PowerShellDataFile (Join-Path $PSScriptRoot $f)
    Assert { $cfg.ContainsKey('VendorKey') -and $cfg.ContainsKey('Targets') } "$f has VendorKey+Targets"
    $devs = @($cfg.Targets.Devices)
    Assert { $devs.Count -eq $expectKeys[$f] } "$f device count = $($expectKeys[$f]) (got $($devs.Count))"
    $bad = $devs | Where-Object { -not ($_.ContainsKey('Key') -and $_.ContainsKey('Label') -and $_.ContainsKey('Queries')) }
    Assert { $bad.Count -eq 0 } "$f all devices have Key/Label/Queries"
}
# Specific fix assertions
$ie = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'intel-eth.psd1')
$e810 = $ie.Targets.Devices | Where-Object Key -eq 'E810'
Assert { $e810.Queries[0] -eq 'VEN_8086&DEV_1592' } 'E810 bare HWID query'
$x520 = $ie.Targets.Devices | Where-Object Key -eq 'X520'
Assert { ($null -ne $x520) -and ($x520.Queries -contains 'VEN_8086&DEV_10FB') } 'X520 (82599) added, includes 10FB'
$mv = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'marvell.psd1')
$aqc = $mv.Targets.Devices | Where-Object Key -eq 'AQC111U'
Assert { $aqc.Queries[0] -eq 'VID_2ECA&PID_C101' } 'AQC111U fixed USB id'
# AQC107+AQC113 merged into one AQC1xx family device (both resolve to the byte-identical
# unified aqnic650 driver); both HWIDs are queried for robustness.
$aqcFam = $mv.Targets.Devices | Where-Object Key -eq 'AQC1xx'
Assert { ($null -ne $aqcFam) -and ($aqcFam.Queries -contains 'VEN_1D6A&DEV_D107') -and ($aqcFam.Queries -contains 'VEN_1D6A&DEV_04C0') } 'AQC1xx merges AQC107(D107)+AQC113(04C0)'
# FastLinQ (qend) is NOT on the catalog; the old name entry only pulled redundant Aquantia.
$fl = $mv.Targets.Devices | Where-Object Key -eq 'FastLinQ'
Assert { $null -eq $fl } 'FastLinQ entry removed (qend not catalog-available)'
$iw = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'intel-wifi.psd1')
$be = $iw.Targets.Devices | Where-Object Key -eq 'BE200'
Assert { $be.Queries[0] -eq 'VEN_8086&DEV_272B' } 'BE200 keeps correct 272B (not gonefishin 2725)'
$md = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'mediatek.psd1')
$mt7925 = $md.Targets.Devices | Where-Object Key -eq '7925'
Assert { $mt7925.PreferredBranches[0] -eq '26.30' } 'MT7925 preferred branch refreshed to 26.30'
# Realtek RTL8157/8159 carry a MinVersion floor so the stale 2016 generic driver is skipped.
$rt = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'realtek.psd1')
$rt57 = $rt.Targets.Devices | Where-Object Key -eq '1157'
$rt59 = $rt.Targets.Devices | Where-Object Key -eq '1159'
Assert { (ConvertTo-CsVersion $rt57.MinVersion) -eq (ConvertTo-CsVersion '1157') } 'realtek RTL8157 has MinVersion 1157 floor'
Assert { (ConvertTo-CsVersion $rt59.MinVersion) -eq (ConvertTo-CsVersion '1159') } 'realtek RTL8159 has MinVersion 1159 floor'

# GPU graphics tables: unified Intel device, NVIDIA consumer/pro split, AMD Radeon Pro present.
$ig = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'intel-gfx.psd1')
$arcXe = $ig.Targets.Devices | Where-Object Key -eq 'Arc_Xe'
Assert { ($null -ne $arcXe) -and ($arcXe.Queries.Count -ge 2) -and ($arcXe.Queries -contains 'VEN_8086&DEV_E20B') } 'intel-gfx Arc_Xe unified (multi-HWID, incl Arc B580 E20B)'
$ng = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'nvidia-gfx.psd1')
$nvGeForce = $ng.Targets.Devices | Where-Object Key -eq 'GeForce'
$nvPro = $ng.Targets.Devices | Where-Object Key -eq 'RTX_Pro'
Assert { ($nvGeForce.Queries -contains 'VEN_10DE&DEV_2684') -and ($nvPro.Queries -contains 'VEN_10DE&DEV_26B1') } 'nvidia-gfx splits consumer GeForce (2684) from RTX-pro (26B1)'
$ag = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'amd-gfx.psd1')
$amdPro = $ag.Targets.Devices | Where-Object Key -eq 'ProW7000'
Assert { $amdPro.Queries[0] -eq 'VEN_1002&DEV_7448' } 'amd-gfx Radeon Pro W7900 (7448) present'

"`n== RESULT: $script:pass passed, $script:fail failed =="
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
