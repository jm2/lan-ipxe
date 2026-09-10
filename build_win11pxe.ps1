#Requires -Version 7.0
<#
.SYNOPSIS
Creates a network-bootable (iSCSI) Windows 11 VHDX from a standard ISO.

.DESCRIPTION
This script automates the creation of a "Win2Go" VHDX for iPXE network booting.
It mounts the Windows ISO, creates and formats a dynamically expanding VHDX,
applies the Windows image, writes boot files, and injects registry changes
to allow the OS to boot from an iSCSI target (iBFT).

.EXAMPLE
.\build_win11pxe.ps1 -IsoPath .\Win11_25H2_English_x64.iso -OutPath .\win11_netboot.vhdx -ImageIndex 6

.EXAMPLE
.\build_win11pxe.ps1 -IsoPath .\Win11_25H2_English_x64.iso -Drivers -GraphicsDrivers NVIDIA -Updates
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$IsoPath = ".\Win11_25H2_English_x64.iso",

    [Parameter(Mandatory = $false)]
    [string]$OutPath = ".\win11_netboot.vhdx",

    [Parameter(Mandatory = $false)]
    [long]$SizeBytes = 128GB,

    [Parameter(Mandatory = $false)]
    [int]$ImageIndex = 6, # Windows 11 Pro is typically index 6 on standard media

    [Parameter(Mandatory = $false)]
    [switch]$Drivers,

    # Use extracted, tested packages instead of the NIC catalog scrapers.
    # May be combined with -GraphicsDrivers, but not -Drivers.
    [Parameter(Mandatory = $false)]
    [string[]]$DriverPath,

    [Parameter(Mandatory = $false)]
    [switch]$Updates,

    # Inject GPU display drivers (post-boot only; a GPU never serves iSCSI boot, so unlike the NIC
    # scrapers these get NO boot-start promotion — see the $nicDriverDefs note). Catalog-sourced like
    # every other scraper. GPU CABs are large (~0.6-1.2 GB each), so this is opt-in and separate from
    # -Drivers. 'All' runs Intel+AMD+NVIDIA (heavier, ~3-5 GB union); pick a single vendor to inject only
    # the target machine's GPU driver. x64 only — discrete GPUs have no ARM64 Windows driver.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Intel', 'AMD', 'NVIDIA', 'All')]
    [string]$GraphicsDrivers,

    # Optional DISM /Add-NetAdapter preparation. The adapter must be present in
    # THIS Windows session; a GUID copied from another machine is insufficient.
    # Get-CimInstance Win32_NetworkAdapter | Select-Object GUID,Name,ServiceName
    # GUID-less builds remain available with boot-NIC preparation unverified.
    [Parameter(Mandatory = $false)]
    [string[]]$BootAdapterGuid
)

# Check for Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please run this script as an Administrator!"
    exit 1
}

if (-not (Test-Path -Path $IsoPath)) {
    Write-Error "ISO file not found at $IsoPath"
    exit 1
}

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'win11pxe\BuildHelpers.psm1') -Force
$buildId = [guid]::NewGuid().ToString('N')
$report = [ordered]@{
    SchemaVersion = 1; BuildId = $buildId; StartedUtc = [datetime]::UtcNow.ToString('o')
    State = 'Building'; OutputPath = $OutPath; WorkingPath = $null
    IsoPath = $IsoPath; ImageIndex = $ImageIndex; SourceImageVersion = $null
    ServicedImageVersion = $null; ServicedKernelVersion = $null; DismVersion = $null; DismLog = $null
    DriverPaths = @(); BootAdapters = @(); BootNicPreparation = 'Unverified'
    ColdBootValidated = $false; NicPackages = @()
    DismOperations = [System.Collections.Generic.List[object]]::new()
    Services = [System.Collections.Generic.List[object]]::new()
    Warnings = [System.Collections.Generic.List[string]]::new()
    Failure = $null
}
$success = $false
$vhdCreated = $false
$sysHiveLoaded = $false
$softHiveLoaded = $false
$isoImage = $null
$workingPath = $null
$reportPath = $null
$dismScratchDir = $null
$driverTempPath = $null
$updatesTempPath = $null
$tempHiveName = $null
$tempSoftName = $null

# Unload an offline registry hive reliably. The PowerShell registry provider
# caches key handles, so reg unload often fails the first time with "Access is
# denied" until the handles are released — hence the GC + retry loop. Returns
# $true on success. Used both in the main flow and in the finally cleanup.
function Dismount-Hive {
    param([string]$HiveName)
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not (Test-Path "HKLM:\$HiveName")) { return $true }
    for ($i = 0; $i -lt 5; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        reg unload "HKLM\$HiveName" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

try {
    # Track loaded offline hives so the finally block can unload them on any
    # mid-way throw (a left-loaded hive locks the VHDX and breaks the next run).
    $sysHiveLoaded = $false
    $softHiveLoaded = $false
    # Convert paths to absolute to prevent issues with Mount-DiskImage
    $IsoPath = Convert-Path $IsoPath
    $OutPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
    if ([System.IO.Path]::GetExtension($OutPath) -ine '.vhdx') { throw '-OutPath must use the .vhdx extension.' }
    $workingPath = Join-Path (Split-Path $OutPath -Parent) ".win11-$buildId.building.vhdx"
    $reportPath = "$OutPath.$buildId.build.json"
    $dismLogPath = "$OutPath.$buildId.dism.log"
    $report.OutputPath = $OutPath; $report.WorkingPath = $workingPath
    $report.IsoPath = $IsoPath; $report.DismLog = $dismLogPath

    # Validate explicit inputs before allocating a VHDX. Existing output is never
    # removed up front, including when a requested adapter cannot be prepared.
    if ($Drivers -and $DriverPath) { throw 'Use either -DriverPath or -Drivers, not both.' }
    $localDriverPaths = @(Resolve-PxeDriverPath -Path $DriverPath | Select-Object -Unique)
    $report.DriverPaths = $localDriverPaths
    $bootAdapters = @()
    if ($BootAdapterGuid) {
        $bootAdapters = @(Resolve-PxeBootAdapter -Guid $BootAdapterGuid -Adapters @(Get-CimInstance Win32_NetworkAdapter))
        $report.BootAdapters = $bootAdapters
    }
    $report.DismVersion = (Get-Item (Get-Command dism.exe -CommandType Application).Source).VersionInfo.FileVersion
    if (-not (Test-Path (Join-Path $PSScriptRoot 'win11pxe\DisableNetPower.ps1'))) {
        throw 'Missing win11pxe\DisableNetPower.ps1 runtime helper.'
    }
    Write-PxeBuildReport $report $reportPath

    Write-Host ">>> Creating temporary VHDX at $workingPath ($($SizeBytes / 1GB) GB)..." -ForegroundColor Cyan
    New-VHD -Path $workingPath -Dynamic -SizeBytes $SizeBytes | Out-Null
    $vhdCreated = $true
    Mount-VHD -Path $workingPath | Out-Null

    # Re-query the disk number after a settle delay rather than trusting the
    # Mount-VHD -PassThru snapshot (DiskNumber is not always populated yet, and a
    # fixed Start-Sleep before reading it cannot help). Retry until it appears.
    $diskNumber = $null
    for ($i = 0; $i -lt 10 -and $null -eq $diskNumber; $i++) {
        Start-Sleep -Seconds 1
        $diskNumber = (Get-VHD -Path $workingPath).DiskNumber
    }
    if ($null -eq $diskNumber) {
        throw "Mounted VHDX never exposed a disk number; cannot continue."
    }

    Write-Host ">>> Initializing Disk $diskNumber (GPT)..." -ForegroundColor Cyan
    Initialize-Disk -Number $diskNumber -PartitionStyle GPT

    # Wipe any auto-generated partitions (like the default MSR) to start clean
    Get-Partition -DiskNumber $diskNumber | Remove-Partition -Confirm:$false

    # Recommended UEFI partition layout
    # Resolve a partition's drive letter, assigning one explicitly if Windows
    # declined to auto-assign (common for ESP-typed partitions). Throws rather
    # than letting a $null letter produce paths like ":\" downstream.
    function Resolve-DriveLetter {
        param($Partition, [string]$What)
        $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
        if (-not $p.DriveLetter -or $p.DriveLetter -eq "`0") {
            $used = (Get-Volume | Where-Object DriveLetter).DriveLetter
            $free = 68..90 | ForEach-Object { [char]$_ } | Where-Object { $_ -notin $used } | Select-Object -First 1
            if (-not $free) { throw "No free drive letter available to assign to $What partition." }
            Set-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -NewDriveLetter $free
            $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
        }
        if (-not $p.DriveLetter -or $p.DriveLetter -eq "`0") {
            throw "Could not obtain a drive letter for the $What partition."
        }
        return $p.DriveLetter
    }

    Write-Host ">>> Creating EFI Partition..." -ForegroundColor Cyan
    $efiPartition = New-Partition -DiskNumber $diskNumber -Size 100MB -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter
    Format-Volume -Partition $efiPartition -FileSystem FAT32 -NewFileSystemLabel "System" | Out-Null

    Write-Host ">>> Creating MSR Partition..." -ForegroundColor Cyan
    New-Partition -DiskNumber $diskNumber -Size 16MB -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" | Out-Null

    Write-Host ">>> Creating Windows Partition..." -ForegroundColor Cyan
    $winPartition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $winPartition -FileSystem NTFS -NewFileSystemLabel "Windows" | Out-Null

    $efiDriveLetter = Resolve-DriveLetter -Partition $efiPartition -What "EFI"
    $winDriveLetter = Resolve-DriveLetter -Partition $winPartition -What "Windows"
    $efiDrivePath = "${efiDriveLetter}:\"
    $winDrivePath = "${winDriveLetter}:\"

    Write-Host ">>> Mounting ISO ($IsoPath)..." -ForegroundColor Cyan
    $isoImage = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $isoDriveLetter = $null
    for ($i = 0; $i -lt 10 -and -not $isoDriveLetter; $i++) {
        Start-Sleep -Seconds 1
        $isoDriveLetter = ($isoImage | Get-Volume).DriveLetter
    }
    if (-not $isoDriveLetter) { throw "Mounted ISO did not expose a drive letter." }
    $wimPath = "${isoDriveLetter}:\sources\install.wim"
    
    if (-not (Test-Path $wimPath)) {
        $wimPath = "${isoDriveLetter}:\sources\install.esd"
    }

    if (-not (Test-Path $wimPath)) {
        throw "Could not find install.wim or install.esd in $IsoPath"
    }

    # Create a scratch directory on a drive with adequate space for DISM operations
    $dismScratchDir = Join-Path $env:TEMP "DISM_Scratch_$(Get-Random)"
    New-Item -ItemType Directory -Path $dismScratchDir -Force | Out-Null
    $imgInfo = Get-WindowsImage -ImagePath $wimPath -Index $ImageIndex -ErrorAction Stop
    $report.SourceImageVersion = [string]$imgInfo.Version
    if ([string]$imgInfo.Architecture -notin '9', 'x64', 'amd64') {
        throw "This builder requires an x64 Windows image (found $($imgInfo.Architecture))."
    }

    Write-Host ">>> Applying Windows Image (Index $ImageIndex) from $wimPath to VHDX..." -ForegroundColor Cyan
    Write-Host "    DISM Log: $dismLogPath" -ForegroundColor DarkGray
    # Using DISM to apply the image. Tokens are quoted so paths containing spaces
    # (e.g. a %TEMP% under a profile name with spaces) survive argument splitting.
    Invoke-PxeDism -Report $report -Arguments @('/Apply-Image', "/ImageFile:$wimPath", "/Index:$ImageIndex", "/ApplyDir:$winDrivePath", "/LogPath:$dismLogPath")

    if ($Drivers -or $GraphicsDrivers) {
        Write-Host ">>> Executing Driver Scrapers (parallel)..." -ForegroundColor Cyan
        $driverTempPath = Join-Path $env:TEMP "Win11Drivers_$(Get-Random)"
        # Pre-create the root so the post-run enumeration never hits a missing path
        # when every scraper fails.
        New-Item -ItemType Directory -Path $driverTempPath -Force | Out-Null

        # NIC/Wi-Fi scrapers (-Drivers). Graphics shims are named Get-*GraphicsDrivers.ps1 and are
        # EXCLUDED here so they run only on explicit -GraphicsDrivers opt-in (their CABs are large).
        $driverScripts = @()
        if ($Drivers) {
            $driverScripts += Get-ChildItem -Path $PSScriptRoot -Filter "Get-*Drivers.ps1" |
                Where-Object { $_.Name -notlike '*Graphics*' }
        }
        # GPU scrapers (-GraphicsDrivers Intel|AMD|NVIDIA|All). All feed the SAME $driverTempPath and the
        # single DISM /Add-Driver below; a GPU is post-boot-only so none is added to $nicDriverDefs.
        if ($GraphicsDrivers) {
            $gpuShims = [ordered]@{
                Intel  = 'Get-IntelGraphicsDrivers.ps1'
                AMD    = 'Get-AmdGraphicsDrivers.ps1'
                NVIDIA = 'Get-NvidiaGraphicsDrivers.ps1'
            }
            $wantedGpu = if ($GraphicsDrivers -eq 'All') { $gpuShims.Values } else { @($gpuShims[$GraphicsDrivers]) }
            foreach ($gpuName in $wantedGpu) {
                $gpuPath = Join-Path $PSScriptRoot $gpuName
                if (Test-Path $gpuPath) { $driverScripts += Get-Item $gpuPath }
                else { Add-PxeBuildWarning $report "    [!] Graphics scraper not found: $gpuName" }
            }
        }

        # GPU CABs are far larger than NIC CABs, so allow more wall-clock when graphics are included.
        # NOTE: this Wait-Job timeout is a single GLOBAL budget shared across all scrapers.
        $scraperTimeoutSec = if ($GraphicsDrivers) { 3600 } else { 1800 }

        # Launch all scrapers concurrently — each writes to its own subdirectory
        $scraperJobs = foreach ($script in $driverScripts) {
            Write-Host "    -> Launching $($script.Name)..."
            Start-ThreadJob -ScriptBlock {
                param($ScriptPath, $DlPath, $Arch)
                & $ScriptPath -DownloadPath $DlPath -Architecture $Arch
            } -ArgumentList $script.FullName, $driverTempPath, "x64" -Name $script.BaseName
        }

        # Wait for all scrapers (bounded) with live status. A scraper that errors
        # must NOT abort the build — Receive-Job under $ErrorActionPreference='Stop'
        # would otherwise rethrow a single flaky HTTP failure as terminating, after
        # the hour-long image apply. -ErrorAction Continue keeps it non-fatal.
        Write-Host "    -> Waiting for $($scraperJobs.Count) scrapers to complete (max $([int]($scraperTimeoutSec / 60)) min)..."
        $scraperJobs | Wait-Job -Timeout $scraperTimeoutSec | Out-Null
        foreach ($job in $scraperJobs) {
            if ($job.State -in 'Running', 'NotStarted') {
                Add-PxeBuildWarning $report "    [!] $($job.Name) timed out — stopping."
                Stop-Job $job
            }
            elseif ($job.State -ne 'Completed') {
                Add-PxeBuildWarning $report "    [!] $($job.Name) ended in state $($job.State): $($job.JobStateInfo.Reason)"
            }
            else {
                Write-Host "    -> $($job.Name) completed." -ForegroundColor Green
            }
            foreach ($record in @(Receive-Job $job -ErrorAction Continue 2>&1 3>&1)) {
                if ($record -is [System.Management.Automation.WarningRecord] -or $record -is [System.Management.Automation.ErrorRecord]) {
                    Add-PxeBuildWarning $report "$($job.Name): $record"
                }
                else { $record | Out-Host }
            }
            Remove-Job $job -Force
        }

        # Re-extract any nested CABs (some Update Catalog packages are double-wrapped)
        Write-Host ">>> Checking for nested CAB files..." -ForegroundColor Cyan
        $nestedCabs = Get-ChildItem -Path $driverTempPath -Filter *.cab -Recurse
        foreach ($cab in $nestedCabs) {
            $cabExtractDir = Join-Path $cab.DirectoryName $cab.BaseName
            if (-not (Test-Path $cabExtractDir)) { New-Item -ItemType Directory -Path $cabExtractDir -Force | Out-Null }
            Write-Host "    -> Re-extracting nested: $($cab.Name)"
            $proc = Start-Process "expand.exe" -ArgumentList "-F:* `"$($cab.FullName)`" `"$cabExtractDir`"" -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -ne 0) {
                # Keep the CAB so a partial/corrupt extraction can be inspected or retried,
                # instead of silently discarding the only copy of a driver family.
                Add-PxeBuildWarning $report "    [!] expand.exe failed ($($proc.ExitCode)) on $($cab.Name); leaving CAB in place."
            }
            else {
                Remove-Item $cab.FullName -Force
            }
        }

        Write-Host ">>> Injecting Drivers into Offline Image..." -ForegroundColor Cyan
        Invoke-PxeDism -Report $report -Arguments @("/Image:$winDrivePath", '/Add-Driver', "/Driver:$driverTempPath", '/Recurse', "/LogPath:$dismLogPath")

        Write-Host ">>> Cleaning up Driver Temp Path..."
        Remove-Item -Path $driverTempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($path in $localDriverPaths) {
        $driverArgs = @("/Image:$winDrivePath", '/Add-Driver', "/Driver:$path", "/LogPath:$dismLogPath")
        if (Test-Path -LiteralPath $path -PathType Container) { $driverArgs += '/Recurse' }
        Invoke-PxeDism -Report $report -Arguments $driverArgs
    }

    if ($Updates) {
        Write-Host ">>> Executing Updates Scraper..." -ForegroundColor Cyan
        # Derive the servicing version from the IMAGE build number (authoritative)
        # rather than the ISO filename, which only matches Microsoft's consumer
        # naming. Map build -> release; abort the update step on an unknown build
        # rather than silently targeting the wrong cumulative-update stream.
        $win11Version = $null
        $buildToVersion = @{ 22621 = "22H2"; 22631 = "23H2"; 26100 = "24H2"; 26200 = "25H2" }
        try {
            $imgInfo = Get-WindowsImage -ImagePath $wimPath -Index $ImageIndex -ErrorAction Stop
            if ($imgInfo.Version -match '^\d+\.\d+\.(\d+)\.') {
                $build = [int]$matches[1]
                if ($buildToVersion.ContainsKey($build)) {
                    $win11Version = $buildToVersion[$build]
                    Write-Host "    -> Image build $build -> Windows 11 $win11Version" -ForegroundColor DarkGray
                }
                else {
                    Add-PxeBuildWarning $report "    [!] Unrecognized image build $build; cannot map to a servicing version."
                }
            }
        }
        catch {
            Add-PxeBuildWarning $report "    [!] Could not read image version: $($_.Exception.Message)"
        }
        if (-not $win11Version) {
            if ($IsoPath -match "Win11_([0-9]{2}H[0-9])_") {
                $win11Version = $matches[1]
                Add-PxeBuildWarning $report "    [!] Falling back to ISO-filename version: $win11Version"
            }
            else {
                $win11Version = "25H2"
                Add-PxeBuildWarning $report "    [!] Defaulting to $win11Version — updates may target the wrong stream."
            }
        }

        $updatesTempPath = Join-Path $env:TEMP "Win11Updates_$(Get-Random)"
        $updateScript = Join-Path $PSScriptRoot "Get-Win11CumulativeUpdates.ps1"
        if (Test-Path $updateScript) {
            Write-Host "    -> Running Get-Win11CumulativeUpdates.ps1 (Targeting $win11Version)..."
            # Run in a child scope guarded by try/catch so a transient network
            # failure in the CU fetch degrades to "no packages" instead of aborting
            # the entire build (this runs in-session and would otherwise inherit
            # $ErrorActionPreference='Stop').
            try {
                & $updateScript -Version $win11Version -DownloadPath $updatesTempPath
            }
            catch {
                Add-PxeBuildWarning $report "    [!] Cumulative-update fetch failed: $($_.Exception.Message). Continuing without updates."
            }

            $packages = Get-ChildItem -Path $updatesTempPath -Include *.msu, *.cab -Recurse -ErrorAction SilentlyContinue
            if ($packages) {
                Write-Host ">>> Injecting Cumulative Updates into Offline Image..." -ForegroundColor Cyan
                Write-Host "    -> $($packages.Count) package(s) found. Using folder-based DISM for automatic dependency resolution."
                foreach ($pkg in $packages) {
                    Write-Host "    -> Queued: $($pkg.Name)" -ForegroundColor DarkGray
                }
                # Point DISM at the entire folder so it can auto-resolve checkpoint
                # CU dependencies and install packages in the correct order.
                # /ScratchDir is critical — CUs are multi-GB and the default 64 MB
                # scratch space inside the offline image is far too small.
                Invoke-PxeDism -Report $report -Arguments @("/Image:$winDrivePath", '/Add-Package', "/PackagePath:$updatesTempPath", "/ScratchDir:$dismScratchDir", "/LogPath:$dismLogPath")
            }
            else {
                Write-Host "    [!] No .msu/.cab packages found after scraping." -ForegroundColor Yellow
            }

            Write-Host ">>> Cleaning up Updates Temp Path..."
            Remove-Item -Path $updatesTempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "    [!] Get-Win11CumulativeUpdates.ps1 not found, skipping updates." -ForegroundColor Yellow
        }
    }

    # Clean up DISM scratch directory
    Remove-Item -Path $dismScratchDir -Recurse -Force -ErrorAction SilentlyContinue

    # /Add-NetAdapter is an undocumented Setup operation using a live HOST
    # adapter. A successful invocation is preparation, not proof of a cold boot.
    # Staging drivers alone does not validate the boot-critical network path.
    $winDir = Join-Path $winDrivePath 'Windows'
    $report.ServicedKernelVersion = (Get-Item (Join-Path $winDir 'System32\ntoskrnl.exe')).VersionInfo.FileVersion
    $report.NicPackages = @(Get-WindowsDriver -Path $winDrivePath -All | Where-Object ClassName -eq 'Net' |
        Select-Object Driver, OriginalFileName, ProviderName, ClassName, Date, Version, Inbox, BootCritical)
    if ($bootAdapters.Count) {
        Write-Host ">>> Installing boot NIC(s) into offline image (DISM /Add-NetAdapter)..." -ForegroundColor Cyan
        foreach ($adapter in $bootAdapters) {
            $g = $adapter.Guid
            Write-Host "    -> /Add-NetAdapter /HostAdapter:$g" -ForegroundColor DarkGray
            Invoke-PxeDism -Report $report -Arguments @("/Image:$winDrivePath", '/Add-NetAdapter', "/HostAdapter:$g", '/BootDriver:ms_tcpip', '/BootDriver:ms_tcpip6', "/LogPath:$dismLogPath")
        }
        $report.BootNicPreparation = 'Applied; cold boot unverified'
    }
    else {
        Add-PxeBuildWarning $report 'No -BootAdapterGuid supplied: boot-NIC preparation is unverified. Staged drivers and service promotion do not establish first-boot compatibility.'
    }

    Write-Host ">>> Writing Boot Files (BCDBoot)..." -ForegroundColor Cyan
    $winDir = Join-Path $winDrivePath "Windows"
    & bcdboot "$winDir" /s "$efiDrivePath" /f UEFI
    if ($LASTEXITCODE -ne 0) {
        throw "BCDBoot failed with exit code $LASTEXITCODE"
    }

    Write-Host ">>> Enabling Verbose SOS Mode and Boot Logging..." -ForegroundColor Cyan
    $bcdStore = Join-Path $efiDrivePath "EFI\Microsoft\Boot\BCD"
    # Wrapper that surfaces bcdedit failures — native commands do not throw under
    # PS7 by default, and a silently-missing 'recoveryenabled no' sends a failed
    # boot into the WinRE repair loop (which also can't see the iSCSI disk),
    # masking the very 0x7B these sos/bootlog flags exist to diagnose.
    function Invoke-Bcd {
        param([string[]]$BcdArgs)
        & bcdedit /store "$bcdStore" @BcdArgs
        if ($LASTEXITCODE -ne 0) { Add-PxeBuildWarning $report "    [!] bcdedit $($BcdArgs -join ' ') failed (exit $LASTEXITCODE)." }
    }
    Invoke-Bcd @('/set', '{default}', 'sos', 'on')
    Invoke-Bcd @('/set', '{default}', 'bootlog', 'yes')
    Invoke-Bcd @('/set', '{globalsettings}', 'bootuxdisabled', 'on')
    Invoke-Bcd @('/set', '{default}', 'recoveryenabled', 'no')

    Write-Host ">>> Injecting iSCSI and Network Boot Settings..." -ForegroundColor Cyan
    # Load the offline SYSTEM registry hive directly from the applied image
    $sysHivePath = Join-Path $winDir "System32\config\SYSTEM"
    $tempHiveName = "VHDX_${buildId}_SYSTEM"

    # Fail fast on stale state from a prior aborted run, then load with an
    # exit-code check (reg.exe does not throw under PS7 by default).
    if (Test-Path "HKLM:\$tempHiveName") {
        throw "HKLM\$tempHiveName is already loaded (stale from a previous run). Unload it (reg unload HKLM\$tempHiveName) and retry."
    }
    reg load "HKLM\$tempHiveName" "$sysHivePath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load of SYSTEM hive failed (exit $LASTEXITCODE)." }
    $sysHiveLoaded = $true

    $controlSets = @(Get-ChildItem "HKLM:\$tempHiveName" | Where-Object PSChildName -match '^ControlSet\d{3}$' | Select-Object -ExpandProperty PSChildName)
    if (-not $controlSets.Count) { throw 'No offline SYSTEM control sets found.' }

    # Index every .sys in the DriverStore ONCE. FileRepository holds thousands of
    # directories and the per-def recursive search was running ~45 times per
    # control set (up to ~90 full-tree walks). Build a name->file map up front.
    $driverStorePath = Join-Path $winDrivePath "Windows\System32\DriverStore\FileRepository"
    $bootDriverDir = Join-Path $winDrivePath "Windows\System32\drivers"
    $sysIndex = @{}
    if (Test-Path $driverStorePath) {
        Get-ChildItem -Path $driverStorePath -Recurse -Filter *.sys -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $sysIndex.ContainsKey($_.Name)) { $sysIndex[$_.Name] = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
            $sysIndex[$_.Name].Add($_)
        }
    }
    $anyBootNic = $false

    foreach ($cs in $controlSets) {
        Write-Host "  Configuring $cs..." -ForegroundColor DarkGray

        # 1. Core iSCSI and network-stack drivers — promote to boot-start.
        #    Only real kernel drivers belong here. Group/ServiceGroupOrder writes
        #    were removed: the in-box Group values are already correct, and the old
        #    "0x7B is iScsiPrt lacking a Group" theory is unsupported. Removed from
        #    this list vs. earlier versions: MSiSCSI (a user-mode svchost service —
        #    Start=0 is invalid for it and breaks post-boot initiator management),
        #    Winsock (a config key, not a loadable driver), and netfs (does not
        #    exist on Windows). The actual boot path still needs hardware testing.
        $coreServices = @("iScsiPrt", "NDIS", "Tcpip", "NetBT")
        foreach ($service in $coreServices) {
            $regPath = "HKLM:\$tempHiveName\$cs\Services\$service"
            if (Test-Path $regPath) {
                Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
                $flags = (Get-ItemProperty -Path $regPath -Name BootFlags -ErrorAction SilentlyContinue).BootFlags
                Set-ItemProperty -Path $regPath -Name "BootFlags" -Value ([int]$flags -bor 1) -Type DWord
                Write-Host "  Promoted Core Stack: $service"
            }
        }

        # 2. Storage and Volume Management (boot-start for iSCSI block storage)
        #    Note: vhdmp is intentionally NOT promoted. The VHDX is converted to a
        #    raw image (qemu-img) and served as a raw iSCSI LUN, so the client never
        #    sees a VHDX container and vhdmp plays no role in this boot path.
        $storageServices = @(
            "partmgr",    # Partition Manager
            "disk",       # Core disk class driver
            "volmgr",     # Volume Manager
            "volmgrx",    # Dynamic Volume Manager
            "vmbus",      # Hyper-V VMBus (if booting under Hyper-V)
            "storvsc"     # Hyper-V storage virtualization
        )
        foreach ($service in $storageServices) {
            $regPath = "HKLM:\$tempHiveName\$cs\Services\$service"
            if (Test-Path $regPath) {
                Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
                Write-Host "  Promoted Storage/Volume: $service"
            }
        }

        # 3. NIC Driver Boot Promotion
        #    DISM /Add-Driver stages packages in the DriverStore but does NOT create
        #    service entries for PnP drivers. For iSCSI boot we need boot-start (Start=0)
        #    service entries, so we find each .sys in the DriverStore, copy it to
        #    System32\drivers, and manually create the service registry key.
        #    NOTE: INF AddService names often differ from .sys basenames (e.g.
        #    e1dexpress → e1d.sys), so Service and Sys are specified independently.
        #    GPU drivers (-GraphicsDrivers: nvlddmkm/amdkmdag/igdkmd*) are deliberately
        #    NOT listed here — a GPU is on neither the boot nor the iSCSI data path
        #    (UEFI GOP → Basic Display Adapter → lazy PnP bind), so it must stay a plain
        #    DISM /Add-Driver with no boot-start promotion. Do not add one.
        $nicDriverDefs = @(
            # --- Virtual Ethernet ---
            @{ Service = "netvsc"; Sys = "netvsc.sys" }          # Hyper-V
            @{ Service = "netkvm"; Sys = "netkvm.sys" }          # VirtIO (QEMU/KVM)
            @{ Service = "vmxnet3ndis6"; Sys = "vmxnet3.sys" }         # VMware

            # --- Intel Ethernet (injected via Get-IntelEthernetDrivers.ps1) ---
            @{ Service = "e2fnexpress"; Sys = "e2fn.sys" }            # I225-V / I226-V 2.5GbE
            @{ Service = "e1dexpress"; Sys = "e1d.sys" }             # I219-V/LM 1GbE
            @{ Service = "e1rexpress"; Sys = "e1r.sys" }             # I210 1GbE
            @{ Service = "ixt62x64"; Sys = "ixt62x64.sys" }        # X540 10GbE
            @{ Service = "ixs"; Sys = "ixs.sys" }             # X550 10GbE
            @{ Service = "i40ea"; Sys = "i40ea.sys" }           # X710/XL710 10/40GbE
            @{ Service = "iavf68"; Sys = "iavf68.sys" }          # Adaptive Virtual Function
            @{ Service = "icea"; Sys = "icea.sys" }           # E810 100GbE (Windows driver is icea; 'ice' is the Linux name)

            # --- Intel Ethernet (in-box MSFT) ---
            @{ Service = "e1i68x64"; Sys = "e1i68x64.sys" }        # I217/I218 1GbE
            @{ Service = "e2f68"; Sys = "e2f68.sys" }           # I225 (older gen) 2.5GbE
            @{ Service = "e1yexpress"; Sys = "e1y60x64.sys" }        # PRO/1000 CT/GT
            @{ Service = "KillerEth"; Sys = "e2xw10x64.sys" }       # Killer E2x00/E3x00

            # --- Realtek PCIe (injected via Get-RealtekEthernetDrivers.ps1) ---
            @{ Service = "rt25cx21x64"; Sys = "rt25cx21x64.sys" }     # RTL8125 2.5GbE
            @{ Service = "rt26cx21x64"; Sys = "rt26cx21x64.sys" }     # RTL8126 2.5GbE
            @{ Service = "rt27cx21x64"; Sys = "rt27cx21x64.sys" }     # RTL8127 10GbE
            @{ Service = "rt68cx21x64"; Sys = "rt68cx21x64.sys" }     # RTL8168 1GbE
            @{ Service = "rt640x64"; Sys = "rt640x64.sys" }        # RTL8168/8111 (legacy NDIS)

            # NOTE: USB NICs (Realtek RTL8153/8156/8157, ASIX, Microchip, etc.) are
            # intentionally NOT in this boot-promotion table. iSCSI boot through a USB
            # NIC requires the whole USB host stack on the paging path, which Windows
            # does not support — boot-promoting them is false coverage. They are still
            # injected via DISM /Add-Driver above for post-boot use.

            # --- Realtek (in-box MSFT) ---
            @{ Service = "RTL8023x64"; Sys = "Rtnic64.sys" }         # Realtek FE (legacy in-box, PCI)

            # --- Broadcom (in-box MSFT) ---
            @{ Service = "b06bdrv"; Sys = "bxvbda.sys" }          # NetXtreme II 10GbE (already Start=0)
            @{ Service = "b57nd60a"; Sys = "b57nd60a.sys" }        # NetXtreme 1GbE
            @{ Service = "k57nd60a"; Sys = "k57nd60a.sys" }        # Broadcom/Killer 1GbE
            @{ Service = "l2nd"; Sys = "bxnd60a.sys" }         # NetXtreme II 1GbE
            @{ Service = "be2net"; Sys = "ocnd65.sys" }          # Emulex/Broadcom OneConnect

            # --- Marvell/Aquantia (injected via Get-MarvellEthernetDrivers.ps1) ---
            @{ Service = "atlantic650"; Sys = "Atlantic650.sys" }     # AQC107 10GbE
            @{ Service = "aqnic650"; Sys = "aqnic650.sys" }        # AQC113 2.5/5/10GbE

            # --- Marvell Yukon (in-box MSFT) ---
            @{ Service = "ykinw8"; Sys = "ykinx64.sys" }         # Yukon 88E8056/8057
            @{ Service = "yukonw8"; Sys = "yk63x64.sys" }         # Yukon legacy

            # --- Mellanox (in-box MSFT) ---
            @{ Service = "mlx5"; Sys = "mlx5.sys" }            # ConnectX-5/6/7
            @{ Service = "mlx4eth63"; Sys = "mlx4eth63.sys" }       # ConnectX-3/4

            # --- Qualcomm/Atheros (in-box MSFT) ---
            @{ Service = "Atc002"; Sys = "l260x64.sys" }         # Atheros L2 FastEthernet
            @{ Service = "AtcL001"; Sys = "l160x64.sys" }         # Atheros L1 GbE
            @{ Service = "L1C"; Sys = "L1C63x64.sys" }        # Killer E2200/Atheros L1C
            @{ Service = "L1E"; Sys = "L1E62x64.sys" }        # Atheros L1E GbE

            # --- Chelsio (in-box MSFT) ---
            @{ Service = "chndis"; Sys = "cht4nx64.sys" }        # T4/T5/T6 10/25/40/100GbE

            # --- NVIDIA (in-box MSFT) ---
            @{ Service = "NVENETFD"; Sys = "nvm60x64.sys" }        # nForce Ethernet
            @{ Service = "NVNET"; Sys = "nvm62x64.sys" }        # nForce Ethernet (newer)

            # (USB Ethernet adapters removed from boot promotion — see note above.)

            # --- JMicron (in-box MSFT) ---
            @{ Service = "NETJME"; Sys = "NETJME.sys" }          # JMC250/JMC260
        )

        $nicPromoted = 0; $nicCreated = 0
        foreach ($def in $nicDriverDefs) {
            $svcName = $def.Service
            $sysName = $def.Sys
            $regPath = "HKLM:\$tempHiveName\$cs\Services\$svcName"

            if (Test-Path $regPath) {
                # In-box driver with existing service entry — promote to boot-start
                Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
                $flags = (Get-ItemProperty -Path $regPath -Name BootFlags -ErrorAction SilentlyContinue).BootFlags
                Set-ItemProperty -Path $regPath -Name "BootFlags" -Value ([int]$flags -bor 1) -Type DWord
                Write-Host "  Promoted NIC Driver: $svcName (in-box)"
                $nicPromoted++; $anyBootNic = $true
            }
            elseif ($sysIndex.ContainsKey($sysName)) {
                # Staged in DriverStore but no service yet — copy the .sys to
                # System32\drivers and hand-create a boot-start service entry.
                $sysFile = Select-PxeDriverBinary -Candidates $sysIndex[$sysName].ToArray()
                $destPath = Join-Path $bootDriverDir $sysFile.Name
                if (Test-Path -LiteralPath $destPath) {
                    if ((Get-FileHash -LiteralPath $destPath).Hash -ne (Get-FileHash -LiteralPath $sysFile.FullName).Hash) {
                        throw "Boot binary $destPath differs from selected package $($sysFile.FullName); refusing to retain a mismatched driver."
                    }
                }
                else {
                    Copy-Item $sysFile.FullName $destPath -Force
                }

                New-Item -Path $regPath -Force | Out-Null
                Set-ItemProperty -Path $regPath -Name "Start"        -Value 0 -Type DWord          # Boot-start
                Set-ItemProperty -Path $regPath -Name "Type"         -Value 1 -Type DWord          # Kernel driver
                Set-ItemProperty -Path $regPath -Name "ErrorControl" -Value 1 -Type DWord          # Normal
                Set-ItemProperty -Path $regPath -Name "ImagePath"    -Value "System32\drivers\$($sysFile.Name)" -Type ExpandString
                Set-ItemProperty -Path $regPath -Name "Group"        -Value "NDIS" -Type String
                Set-ItemProperty -Path $regPath -Name "BootFlags"    -Value 1 -Type DWord
                Write-Host "  Promoted NIC Driver: $svcName (created boot-start service)"
                $nicCreated++; $anyBootNic = $true
                Add-PxeBuildWarning $report "Created fallback service $svcName from $($sysFile.FullName). INF/WDF/device installation and cold boot remain unverified."
            }
            # else: driver not in image — not an error (we promote the union of all
            # supported NICs; most won't be present for any given target).
        }
        Write-Host "  NIC summary ($cs): $nicPromoted in-box promoted, $nicCreated created from DriverStore." -ForegroundColor DarkGray

        $auditServices = @($coreServices) + @($storageServices) + @($nicDriverDefs.Service) + @($bootAdapters.ServiceName)
        foreach ($service in ($auditServices | Where-Object { $_ } | Select-Object -Unique)) {
            $audit = Get-PxeServiceAudit -RegistryPath "HKLM:\$tempHiveName" -WindowsPath $winDir -ControlSet $cs -Service $service
            if ($audit) {
                $report.Services.Add($audit)
                if (-not $audit.BinaryExists -or @($audit.StartOverride.Values | Where-Object { $_ -ne 0 }).Count) {
                    Add-PxeBuildWarning $report "$cs/$service needs review: binary exists=$($audit.BinaryExists), StartOverride=$($audit.StartOverride | ConvertTo-Json -Compress)."
                }
            }
            if ($service -in $bootAdapters.ServiceName -and
                (-not $audit -or -not $audit.BinaryExists -or ($audit.Start -ne 0 -and -not ($audit.BootFlags -band 1)))) {
                throw "Requested boot adapter service $service is missing a binary or boot-start configuration in $cs."
            }
        }

        # 4. SAN Policy — OfflineInternal (4): bring iSCSI boot disk online, leave others offline
        $partmgrParamsPath = "HKLM:\$tempHiveName\$cs\Services\partmgr\Parameters"
        if (-not (Test-Path $partmgrParamsPath)) { New-Item -Path $partmgrParamsPath -Force | Out-Null }
        Set-ItemProperty -Path $partmgrParamsPath -Name "SanPolicy" -Value 4 -Type DWord
        Write-Host "  Set SAN Policy: OfflineInternal (4)"

        # 5. Disk timeout — iSCSI is network storage, needs generous timeout
        #    (Removed: Tcpip PollBootPartitionTimeout — a Windows Embedded Standard 7
        #     value with no documented effect on Windows 10/11.)
        $diskRegPath = "HKLM:\$tempHiveName\$cs\Services\disk"
        if (Test-Path $diskRegPath) {
            Set-ItemProperty -Path $diskRegPath -Name "TimeOutValue" -Value 120 -Type DWord
            Write-Host "  Set Disk TimeOutValue: 120 seconds"
        }

        # 7. Disable BitLocker automatic device encryption
        $bitLockerRegPath = "HKLM:\$tempHiveName\$cs\Control\BitLocker"
        if (-not (Test-Path $bitLockerRegPath)) { New-Item -Path $bitLockerRegPath -Force | Out-Null }
        Set-ItemProperty -Path $bitLockerRegPath -Name "PreventDeviceEncryption" -Value 1 -Type DWord
    }
    Write-Host "Disabled BitLocker automatic device encryption"

    if (-not $anyBootNic) {
        Add-PxeBuildWarning $report 'No NIC from the fallback table was promoted. Check the requested adapter service and package in the build report.'
    }

    # Bypass TPM/SecureBoot/RAM checks (LabConfig) — not per-ControlSet
    $labConfigPath = "HKLM:\$tempHiveName\Setup\LabConfig"
    if (-not (Test-Path $labConfigPath)) { New-Item -Path $labConfigPath -Force | Out-Null }
    Set-ItemProperty -Path $labConfigPath -Name "BypassTPMCheck" -Value 1 -Type DWord
    Set-ItemProperty -Path $labConfigPath -Name "BypassSecureBootCheck" -Value 1 -Type DWord
    Set-ItemProperty -Path $labConfigPath -Name "BypassRAMCheck" -Value 1 -Type DWord
    Set-ItemProperty -Path $labConfigPath -Name "BypassStorageCheck" -Value 1 -Type DWord
    Write-Host "Injected LabConfig bypasses for TPM/RAM/SecureBoot"

    # Ensure registry finishes writing, then unload (throw on failure so we never
    # dismount the VHDX with a dirty/loaded hive).
    if (-not (Dismount-Hive $tempHiveName)) { throw "Failed to unload SYSTEM hive ($tempHiveName)." }
    $sysHiveLoaded = $false

    Write-Host ">>> Injecting OOBE Settings into Offline SOFTWARE Registry..." -ForegroundColor Cyan
    $softHivePath = Join-Path $winDir "System32\config\SOFTWARE"
    $tempSoftName = "VHDX_${buildId}_SOFTWARE"
    if (Test-Path "HKLM:\$tempSoftName") {
        throw "HKLM\$tempSoftName is already loaded (stale from a previous run). Unload it and retry."
    }
    reg load "HKLM\$tempSoftName" "$softHivePath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load of SOFTWARE hive failed (exit $LASTEXITCODE)." }
    $softHiveLoaded = $true
    $versionInfo = Get-ItemProperty "HKLM:\$tempSoftName\Microsoft\Windows NT\CurrentVersion"
    $report.ServicedImageVersion = "$($versionInfo.CurrentBuildNumber).$($versionInfo.UBR)"

    # Remove requirement for an online Microsoft account (BypassNRO)
    $oobeRegPath = "HKLM:\$tempSoftName\Microsoft\Windows\CurrentVersion\OOBE"
    if (-not (Test-Path $oobeRegPath)) { New-Item -Path $oobeRegPath -Force | Out-Null }
    Set-ItemProperty -Path $oobeRegPath -Name "BypassNRO" -Value 1 -Type DWord
    Write-Host "Injected BypassNRO (Skip Microsoft Account)"

    if (-not (Dismount-Hive $tempSoftName)) { throw "Failed to unload SOFTWARE hive ($tempSoftName)." }
    $softHiveLoaded = $false

    Write-Host ">>> Creating unattend.xml for User Experience (Local Account, Privacy, Region)..." -ForegroundColor Cyan
    $currentCulture = (Get-Culture).Name
    $unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" language="neutral" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" publicKeyToken="31bf3856ad364e35" versionScope="nonSxS">
            <InputLocale>$currentCulture</InputLocale>
            <SystemLocale>$currentCulture</SystemLocale>
            <UILanguage>$currentCulture</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>$currentCulture</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" language="neutral" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" publicKeyToken="31bf3856ad364e35" versionScope="nonSxS">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Home</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value></Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Description>Local Admin</Description>
                        <DisplayName>lan</DisplayName>
                        <Group>Administrators</Group>
                        <Name>lan</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value></Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>9999999</LogonCount>
                <Username>lan</Username>
            </AutoLogon>
        </component>
    </settings>
</unattend>
"@
    $pantherPath = Join-Path $winDir "Panther"
    if (-not (Test-Path $pantherPath)) { New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null }
    Out-File -FilePath "$pantherPath\unattend.xml" -InputObject $unattendXml -Encoding UTF8
    Write-Host "Saved unattend.xml to bypass privacy questions, set region info ($currentCulture), and configure default account: lan"

    Write-Host ">>> Injecting SetupComplete.cmd for Network Power Management..." -ForegroundColor Cyan
    $setupScriptsPath = Join-Path $winDir "Setup\Scripts"
    if (-not (Test-Path $setupScriptsPath)) {
        New-Item -ItemType Directory -Path $setupScriptsPath -Force | Out-Null
    }

    # Keep the Windows PowerShell 5.1 runtime helper independently testable.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'win11pxe\DisableNetPower.ps1') -Destination $setupScriptsPath

    $setupCompletePath = Join-Path $setupScriptsPath "SetupComplete.cmd"
    # Use proper cmd.exe quoting — invoke the helper .ps1 directly
    $cmdContent = @"
@echo off
REM Register the startup task and adjust supported settings without restarting NICs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DisableNetPower.ps1" -InstallStartupTask >> "%SystemRoot%\Logs\DisableNetPower-setup.log" 2>&1
if errorlevel 1 exit /b 1
del "%~f0"
"@
    Set-Content -Path $setupCompletePath -Value $cmdContent -Encoding Ascii

    Write-Host ">>> Done! Unmounting images..." -ForegroundColor Cyan
    $success = $true
}
catch {
    $report.Failure = $_.Exception.Message
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
}
finally {
    # Never detach a disk while one of our registry hives is still loaded.
    foreach ($entry in @(@($sysHiveLoaded, $tempHiveName), @($softHiveLoaded, $tempSoftName))) {
        if ($entry[0]) {
            try {
                if (-not (Dismount-Hive $entry[1])) { throw "Could not unload $($entry[1])." }
            }
            catch {
                $success = $false
                Add-PxeBuildWarning $report "$($_.Exception.Message) Retaining the temporary image at $workingPath."
            }
        }
    }
    if ($isoImage) {
        try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop | Out-Null }
        catch {
            $success = $false
            Add-PxeBuildWarning $report "ISO cleanup failed: $($_.Exception.Message)"
        }
    }
    if ($vhdCreated) {
        try {
            if (($tempHiveName -and (Test-Path "HKLM:\$tempHiveName")) -or
                ($tempSoftName -and (Test-Path "HKLM:\$tempSoftName"))) {
                throw 'Offline registry hive still loaded; refusing to dismount.'
            }
            if ((Get-VHD -Path $workingPath -ErrorAction Stop).Attached) {
                Dismount-VHD -Path $workingPath -ErrorAction Stop | Out-Null
            }
            if ((Get-VHD -Path $workingPath -ErrorAction Stop).Attached) { throw 'Temporary VHDX is still attached.' }
        }
        catch {
            $success = $false
            Add-PxeBuildWarning $report "VHDX cleanup failed: $($_.Exception.Message)"
        }
    }
    foreach ($path in @($dismScratchDir, $driverTempPath, $updatesTempPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$report.FinishedUtc = [datetime]::UtcNow.ToString('o')
if ($success) {
    try {
        $report.State = 'ReadyToPublish'
        Publish-PxeImage -WorkingPath $workingPath -OutPath $OutPath -ReportPath $reportPath -Report $report
    }
    catch {
        $success = $false
        $report.Failure = $_.Exception.Message
        Write-Host "Image publication failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
if (-not $success) {
    $report.State = 'Failed'
    if ($reportPath) {
        try { Write-PxeBuildReport $report $reportPath }
        catch { Add-PxeBuildWarning $report "Could not save build report: $($_.Exception.Message)" }
    }
}
if ($reportPath) { Write-Host "Build report: $reportPath" }

if ($success) {
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host " VHDX Creation Complete: $OutPath" -ForegroundColor Green
    Write-Host "----------------------------------------------------------"
    Write-Host " Serve it as a RAW iSCSI LUN (LIO/targetcli serves file"
    Write-Host " bytes raw and does NOT parse the VHDX container):"
    Write-Host "   qemu-img convert -f vhdx -O raw `"$OutPath`" win11.img"
    Write-Host " then point an LIO fileio backstore at win11.img behind"
    Write-Host " iqn.2026-02.lan.pxe:win11, create an ACL for the client"
    Write-Host " initiator IQN, and set ENABLE_WIN11_PXE=true in"
    Write-Host " update-pxe-images.sh."
    Write-Host " Boot-NIC preparation: $($report.BootNicPreparation)" -ForegroundColor Yellow
    Write-Host " Cold boot has not been validated. Review $($report.Warnings.Count) report warning(s)." -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Green
}
else {
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " VHDX Creation Failed!" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    exit 1
}

<#
BOOT-NIC NOTES
Windows can enumerate new hardware during first boot. Missing pre-existing Enum
keys alone do not prove failure; iSCSI needs a working network/storage stack early
enough to access the system volume. Staging a driver is not proof of that path.

-BootAdapterGuid invokes the undocumented DISM /Add-NetAdapter operation using an
adapter present on the machine running this script. Its GUID is session-specific,
not a portable hardware identifier. Failures are fatal when explicitly requested.
GUID-less builds are permitted with preparation marked unverified. Neither mode
replaces a cold-boot test on the intended NIC, firmware and Windows release.

A target log containing only iPXE's login indicates a handoff problem, but does
not distinguish missing NIC setup from driver, iBFT, routing or target failures.
Use the per-build report and DISM log, and capture target-side login/error logs.
Setup over an iBFT-attached LUN remains an alternative when offline preparation
is insufficient; this script does not implement that provisioning workflow.
#>
