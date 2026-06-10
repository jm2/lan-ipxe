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

    [Parameter(Mandatory = $false)]
    [switch]$Updates,

    # Adapter GUID(s) of the boot NIC, for the offline DISM /Add-NetAdapter step
    # that actually makes Windows able to boot over iSCSI (see notes below).
    # Obtain on a live machine / WinPE where that NIC is present:
    #     wmic nic get GUID,Name,ServiceName
    # (the GUID looks like {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}).
    # DEFERRED: auto-detecting/validating the correct adapter from hardware IDs is
    # not yet implemented — the GUID must be supplied by hand for now. Without it,
    # the image will almost certainly 0x7B INACCESSIBLE_BOOT_DEVICE over iSCSI.
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

# Unload an offline registry hive reliably. The PowerShell registry provider
# caches key handles, so reg unload often fails the first time with "Access is
# denied" until the handles are released — hence the GC + retry loop. Returns
# $true on success. Used both in the main flow and in the finally cleanup.
function Dismount-Hive {
    param([string]$HiveName)
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
    $success = $false
    # Track loaded offline hives so the finally block can unload them on any
    # mid-way throw (a left-loaded hive locks the VHDX and breaks the next run).
    $sysHiveLoaded = $false
    $softHiveLoaded = $false
    # Convert paths to absolute to prevent issues with Mount-DiskImage
    $IsoPath = Convert-Path $IsoPath
    $OutPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)

    Write-Host ">>> Creating VHDX at $OutPath ($($SizeBytes / 1GB) GB)..." -ForegroundColor Cyan
    if (Test-Path $OutPath) {
        Write-Host "Removing existing file..."
        Remove-Item $OutPath -Force
    }

    New-VHD -Path $OutPath -Dynamic -SizeBytes $SizeBytes | Out-Null
    $mountedVhd = Mount-VHD -Path $OutPath -PassThru

    # Re-query the disk number after a settle delay rather than trusting the
    # Mount-VHD -PassThru snapshot (DiskNumber is not always populated yet, and a
    # fixed Start-Sleep before reading it cannot help). Retry until it appears.
    $diskNumber = $null
    for ($i = 0; $i -lt 10 -and $null -eq $diskNumber; $i++) {
        Start-Sleep -Seconds 1
        $diskNumber = (Get-VHD -Path $OutPath).DiskNumber
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
    $dismLogPath = Join-Path $env:TEMP "DISM_Build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    Write-Host ">>> Applying Windows Image (Index $ImageIndex) from $wimPath to VHDX..." -ForegroundColor Cyan
    Write-Host "    DISM Log: $dismLogPath" -ForegroundColor DarkGray
    # Using DISM to apply the image. Tokens are quoted so paths containing spaces
    # (e.g. a %TEMP% under a profile name with spaces) survive argument splitting.
    dism.exe /Apply-Image "/ImageFile:$wimPath" /Index:$ImageIndex "/ApplyDir:$winDrivePath" "/LogPath:$dismLogPath"
    if ($LASTEXITCODE -ne 0) {
        throw "DISM /Apply-Image failed with exit code $LASTEXITCODE. Check log: $dismLogPath"
    }

    if ($Drivers) {
        Write-Host ">>> Executing Driver Scrapers (parallel)..." -ForegroundColor Cyan
        $driverTempPath = Join-Path $env:TEMP "Win11Drivers_$(Get-Random)"
        # Pre-create the root so the post-run enumeration never hits a missing path
        # when every scraper fails.
        New-Item -ItemType Directory -Path $driverTempPath -Force | Out-Null
        $driverScripts = Get-ChildItem -Path $PSScriptRoot -Filter "Get-*Drivers.ps1"

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
        Write-Host "    -> Waiting for $($scraperJobs.Count) scrapers to complete (max 30 min)..."
        $scraperJobs | Wait-Job -Timeout 1800 | Out-Null
        foreach ($job in $scraperJobs) {
            if ($job.State -eq 'Running') {
                Write-Warning "    [!] $($job.Name) timed out — stopping."
                Stop-Job $job
            }
            elseif ($job.State -eq 'Failed') {
                Write-Warning "    [!] $($job.Name) failed: $($job.ChildJobs[0].JobStateInfo.Reason)"
            }
            else {
                Write-Host "    -> $($job.Name) completed." -ForegroundColor Green
            }
            Receive-Job $job -ErrorAction Continue 2>&1 | Out-Host
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
                Write-Warning "    [!] expand.exe failed ($($proc.ExitCode)) on $($cab.Name); leaving CAB in place."
            }
            else {
                Remove-Item $cab.FullName -Force
            }
        }

        Write-Host ">>> Injecting Drivers into Offline Image..." -ForegroundColor Cyan
        dism.exe "/Image:$winDrivePath" /Add-Driver "/Driver:$driverTempPath" /Recurse "/LogPath:$dismLogPath"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DISM /Add-Driver completed with exit code $LASTEXITCODE. Some drivers may have been skipped. Check log: $dismLogPath"
        }

        Write-Host ">>> Cleaning up Driver Temp Path..."
        Remove-Item -Path $driverTempPath -Recurse -Force -ErrorAction SilentlyContinue
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
                    Write-Warning "    [!] Unrecognized image build $build; cannot map to a servicing version."
                }
            }
        }
        catch {
            Write-Warning "    [!] Could not read image version: $($_.Exception.Message)"
        }
        if (-not $win11Version) {
            if ($IsoPath -match "Win11_([0-9]{2}H[0-9])_") {
                $win11Version = $matches[1]
                Write-Warning "    [!] Falling back to ISO-filename version: $win11Version"
            }
            else {
                $win11Version = "25H2"
                Write-Warning "    [!] Defaulting to $win11Version — updates may target the wrong stream."
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
                Write-Warning "    [!] Cumulative-update fetch failed: $($_.Exception.Message). Continuing without updates."
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
                dism.exe "/Image:$winDrivePath" /Add-Package "/PackagePath:$updatesTempPath" "/ScratchDir:$dismScratchDir" "/LogPath:$dismLogPath"
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "DISM /Add-Package completed with exit code $LASTEXITCODE. Check log: $dismLogPath"
                    Write-Warning "This may indicate a checkpoint dependency issue or incompatible package."
                }
                else {
                    Write-Host "    -> Cumulative updates applied successfully." -ForegroundColor Green
                }
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

    # ===========================================================================
    # Boot-NIC network installation (the actual fix for the 0x7B over iSCSI)
    # ===========================================================================
    # A DISM-applied image has never run PnP, so its boot NIC has no Enum devnode,
    # no Net-class instance, and no TCP/IP binding — only a Services key. winload
    # then LOADS the NIC driver but the kernel can never BIND it to the hardware,
    # so iScsiPrt cannot re-establish the iBFT session and the boot volume never
    # arrives -> 0x7B INACCESSIBLE_BOOT_DEVICE.
    #
    # /Add-NetAdapter is the (undocumented but real) offline DISM verb Windows
    # Setup itself runs when it detects an iBFT: it creates the offline network
    # interface, binds ms_tcpip/ms_tcpip6, and sets the NIC's boot-critical flag.
    # It needs the boot NIC's adapter GUID, which is machine-specific and must be
    # supplied via -BootAdapterGuid for now (auto-detection from hardware IDs is
    # DEFERRED). If the GUID is omitted we warn loudly rather than silently ship
    # an image that will bugcheck.
    if ($BootAdapterGuid) {
        Write-Host ">>> Installing boot NIC(s) into offline image (DISM /Add-NetAdapter)..." -ForegroundColor Cyan
        foreach ($guid in $BootAdapterGuid) {
            $g = $guid.Trim()
            if ($g -notmatch '^\{?[0-9a-fA-F-]{36}\}?$') {
                Write-Warning "    [!] '$g' does not look like an adapter GUID; skipping."
                continue
            }
            if ($g -notmatch '^\{') { $g = "{$g}" }
            Write-Host "    -> /Add-NetAdapter /HostAdapter:$g" -ForegroundColor DarkGray
            dism.exe "/Image:$winDrivePath" /Add-NetAdapter "/HostAdapter:$g" /BootDriver:ms_tcpip /BootDriver:ms_tcpip6 "/LogPath:$dismLogPath"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "    [!] /Add-NetAdapter failed for $g (exit $LASTEXITCODE)."
                Write-Warning "        This verb is undocumented and not present on every DISM build. If it is"
                Write-Warning "        unavailable, install Windows by booting Setup over the sanhook'd LUN"
                Write-Warning "        (WinPE + iBFT) instead — see the notes block at the end of this script."
            }
            else {
                Write-Host "    -> Boot NIC $g installed and marked boot-critical." -ForegroundColor Green
            }
        }
    }
    else {
        Write-Warning ">>> No -BootAdapterGuid supplied: skipping offline NIC installation."
        Write-Warning "    The resulting image will almost certainly 0x7B INACCESSIBLE_BOOT_DEVICE over"
        Write-Warning "    iSCSI, because the boot NIC is loaded but never PnP-installed. Re-run with"
        Write-Warning "    -BootAdapterGuid {GUID} (from 'wmic nic get GUID,Name,ServiceName' on a machine"
        Write-Warning "    where that NIC is live), or install via Setup-over-iBFT (see notes at end)."
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
        if ($LASTEXITCODE -ne 0) { Write-Warning "    [!] bcdedit $($BcdArgs -join ' ') failed (exit $LASTEXITCODE)." }
    }
    Invoke-Bcd @('/set', '{default}', 'sos', 'on')
    Invoke-Bcd @('/set', '{default}', 'bootlog', 'yes')
    Invoke-Bcd @('/set', '{globalsettings}', 'bootuxdisabled', 'on')
    Invoke-Bcd @('/set', '{default}', 'recoveryenabled', 'no')

    Write-Host ">>> Injecting iSCSI and Network Boot Settings..." -ForegroundColor Cyan
    # Load the offline SYSTEM registry hive directly from the applied image
    $sysHivePath = Join-Path $winDir "System32\config\SYSTEM"
    $tempHiveName = "VHDX_Temp_SYSTEM"

    # Fail fast on stale state from a prior aborted run, then load with an
    # exit-code check (reg.exe does not throw under PS7 by default).
    if (Test-Path "HKLM:\$tempHiveName") {
        throw "HKLM\$tempHiveName is already loaded (stale from a previous run). Unload it (reg unload HKLM\$tempHiveName) and retry."
    }
    reg load "HKLM\$tempHiveName" "$sysHivePath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load of SYSTEM hive failed (exit $LASTEXITCODE)." }
    $sysHiveLoaded = $true

    # Determine which control sets exist for mirroring
    $controlSets = @("ControlSet001")
    if (Test-Path "HKLM:\$tempHiveName\ControlSet002") {
        $controlSets += "ControlSet002"
    }

    # Index every .sys in the DriverStore ONCE. FileRepository holds thousands of
    # directories and the per-def recursive search was running ~45 times per
    # control set (up to ~90 full-tree walks). Build a name->file map up front.
    $driverStorePath = Join-Path $winDrivePath "Windows\System32\DriverStore\FileRepository"
    $bootDriverDir = Join-Path $winDrivePath "Windows\System32\drivers"
    $sysIndex = @{}
    if (Test-Path $driverStorePath) {
        Get-ChildItem -Path $driverStorePath -Recurse -Filter *.sys -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $sysIndex.ContainsKey($_.Name)) { $sysIndex[$_.Name] = $_ }
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
        #    exist on Windows). The actual 0x7B fix is /Add-NetAdapter above.
        $coreServices = @("iScsiPrt", "NDIS", "Tcpip", "NetBT")
        foreach ($service in $coreServices) {
            $regPath = "HKLM:\$tempHiveName\$cs\Services\$service"
            if (Test-Path $regPath) {
                Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
                Set-ItemProperty -Path $regPath -Name "BootFlags" -Value 1 -Type DWord
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
                Set-ItemProperty -Path $regPath -Name "BootFlags" -Value 1 -Type DWord
                Write-Host "  Promoted NIC Driver: $svcName (in-box)"
                $nicPromoted++; $anyBootNic = $true
            }
            elseif ($sysIndex.ContainsKey($sysName)) {
                # Staged in DriverStore but no service yet — copy the .sys to
                # System32\drivers and hand-create a boot-start service entry.
                $sysFile = $sysIndex[$sysName]
                $destPath = Join-Path $bootDriverDir $sysFile.Name
                if (-not (Test-Path $destPath)) {
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
            }
            # else: driver not in image — not an error (we promote the union of all
            # supported NICs; most won't be present for any given target).
        }
        Write-Host "  NIC summary ($cs): $nicPromoted in-box promoted, $nicCreated created from DriverStore." -ForegroundColor DarkGray

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
        Write-Warning "  No boot NIC driver was promoted or created from the image. Unless -BootAdapterGuid"
        Write-Warning "  covers your NIC, this image will 0x7B INACCESSIBLE_BOOT_DEVICE over iSCSI."
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
    $tempSoftName = "VHDX_Temp_SOFTWARE"
    if (Test-Path "HKLM:\$tempSoftName") {
        throw "HKLM\$tempSoftName is already loaded (stale from a previous run). Unload it and retry."
    }
    reg load "HKLM\$tempSoftName" "$softHivePath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load of SOFTWARE hive failed (exit $LASTEXITCODE)." }
    $softHiveLoaded = $true

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

    # Create a helper PowerShell script that SetupComplete.cmd will invoke.
    # This avoids cmd.exe quoting issues with embedded PowerShell syntax.
    $psHelperPath = Join-Path $setupScriptsPath "DisableNetPower.ps1"
    $psHelperContent = @'
Get-NetAdapter | ForEach-Object {
    Set-NetAdapterPowerManagement -Name $_.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction SilentlyContinue
}
'@
    Set-Content -Path $psHelperPath -Value $psHelperContent -Encoding UTF8

    $setupCompletePath = Join-Path $setupScriptsPath "SetupComplete.cmd"
    # Use proper cmd.exe quoting — invoke the helper .ps1 directly
    $cmdContent = @"
@echo off
REM Disable NIC power management on first boot and schedule for subsequent boots
powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0DisableNetPower.ps1"
schtasks /create /f /ru SYSTEM /sc onstart /tn "DisableNetPower" /tr "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\DisableNetPower.ps1"
del "%~f0"
"@
    Set-Content -Path $setupCompletePath -Value $cmdContent -Encoding Ascii

    Write-Host ">>> Done! Unmounting images..." -ForegroundColor Cyan
    $success = $true
}
catch {
    # Use Write-Host, not Write-Error: under $ErrorActionPreference='Stop' a
    # Write-Error in the catch becomes a NEW terminating error and the failure
    # banner below would never run.
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
}
finally {
    # Unload any hive still loaded from a mid-way throw BEFORE dismounting the VHD,
    # otherwise the dismount detaches a volume with a dirty loaded hive (losing the
    # registry edits) and leaves the hive locked until reboot, breaking the next run.
    if ($sysHiveLoaded -and $tempHiveName) {
        if (-not (Dismount-Hive $tempHiveName)) { Write-Warning "Could not unload SYSTEM hive ($tempHiveName); a reboot may be required before the next run." }
    }
    if ($softHiveLoaded -and $tempSoftName) {
        if (-not (Dismount-Hive $tempSoftName)) { Write-Warning "Could not unload SOFTWARE hive ($tempSoftName); a reboot may be required before the next run." }
    }
    # Each dismount in its own guard so one failure cannot skip the others.
    if ($isoImage) {
        try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch { Write-Warning "Dismount-DiskImage failed: $($_.Exception.Message)" }
    }
    if ($mountedVhd) {
        try { Dismount-VHD -Path $OutPath | Out-Null } catch { Write-Warning "Dismount-VHD failed: $($_.Exception.Message)" }
    }
}

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
    if (-not $BootAdapterGuid) {
        Write-Host ""
        Write-Host " WARNING: built WITHOUT -BootAdapterGuid — this image will" -ForegroundColor Yellow
        Write-Host " likely 0x7B over iSCSI. See the boot-NIC notes below." -ForegroundColor Yellow
    }
    Write-Host "==========================================================" -ForegroundColor Green
}
else {
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " VHDX Creation Failed!" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    exit 1
}

<#
===============================================================================
 BOOT-NIC NOTES — why an offline image 0x7Bs over iSCSI, and the options
===============================================================================
A DISM-applied image has never run PnP, so its boot NIC exists only as a
Services key — there is no Enum\PCI devnode, no Net-class instance, and no
TCP/IP interface binding. winload LOADS the NIC driver, but the kernel can
never BIND it to the hardware, so iScsiPrt cannot re-establish the iBFT session
after ExitBootServices and the boot volume never arrives -> 0x7B.

Confirm the diagnosis: during a failing boot, the iSCSI target log shows iPXE's
login but NO second (Windows kernel) login.

This script implements OPTION 3 (chosen): the offline DISM /Add-NetAdapter verb
that Windows Setup itself runs when it detects an iBFT. Pass -BootAdapterGuid
with the boot NIC's adapter GUID (from 'wmic nic get GUID,Name,ServiceName' on a
machine/WinPE where that NIC is live). It creates the offline interface, binds
ms_tcpip/ms_tcpip6, and marks the NIC boot-critical.

DEFERRED: auto-detecting/validating the correct adapter from hardware IDs is not
yet implemented; the GUID must be supplied by hand. (Tracked as a TODO.)

If /Add-NetAdapter is unavailable on your DISM build, use the most reliable
alternative — install Windows by booting Setup over the LUN:
  1. update-pxe-images.sh: add an entry that does
       sanhook --drive 0x80 iscsi:192.168.1.11:::0:iqn.2026-02.lan.pxe:win11
       (with 'set keep-san 1'), then wimboot a WinPE (ADK; DISM the client NIC
       driver into boot.wim) plus the Win11 ISO.
  2. Run setup.exe against the iSCSI disk. On 24H2+ media choose "Previous
     version of setup" (the new setup UI crashes scanning iSCSI disks).
  Setup detects the iBFT, runs /Add-NetAdapter itself, and the image just works.
===============================================================================
#>
