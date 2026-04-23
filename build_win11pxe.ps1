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
    [switch]$Updates
)

# Check for Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please run this script as an Administrator!"
    exit
}

if (-not (Test-Path -Path $IsoPath)) {
    Write-Error "ISO file not found at $IsoPath"
    exit
}

$ErrorActionPreference = "Stop"

try {
    $success = $false
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
    $diskNumber = $mountedVhd.DiskNumber

    # Wait for disk to be available to WMI/CIM
    Start-Sleep -Seconds 3

    Write-Host ">>> Initializing Disk $diskNumber (GPT)..." -ForegroundColor Cyan
    Initialize-Disk -Number $diskNumber -PartitionStyle GPT

    # Wipe any auto-generated partitions (like the default MSR) to start clean
    Get-Partition -DiskNumber $diskNumber | Remove-Partition -Confirm:$false

    # Recommended UEFI partition layout
    Write-Host ">>> Creating EFI Partition..." -ForegroundColor Cyan
    $efiPartition = New-Partition -DiskNumber $diskNumber -Size 100MB -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter
    Format-Volume -Partition $efiPartition -FileSystem FAT32 -NewFileSystemLabel "System"

    Write-Host ">>> Creating MSR Partition..." -ForegroundColor Cyan
    New-Partition -DiskNumber $diskNumber -Size 16MB -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" | Out-Null

    Write-Host ">>> Creating Windows Partition..." -ForegroundColor Cyan
    $winPartition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $winPartition -FileSystem NTFS -NewFileSystemLabel "Windows"

    $efiDrivePath = "$($efiPartition.DriveLetter):\"
    $winDrivePath = "$($winPartition.DriveLetter):\"

    Write-Host ">>> Mounting ISO ($IsoPath)..." -ForegroundColor Cyan
    $isoImage = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $isoDriveLetter = ($isoImage | Get-Volume).DriveLetter
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
    # Using DISM to apply the image
    dism.exe /Apply-Image /ImageFile:$wimPath /Index:$ImageIndex /ApplyDir:$winDrivePath /LogPath:$dismLogPath
    if ($LASTEXITCODE -ne 0) {
        throw "DISM /Apply-Image failed with exit code $LASTEXITCODE. Check log: $dismLogPath"
    }

    if ($Drivers) {
        Write-Host ">>> Executing Driver Scrapers (parallel)..." -ForegroundColor Cyan
        $driverTempPath = Join-Path $env:TEMP "Win11Drivers_$(Get-Random)"
        $driverScripts = Get-ChildItem -Path $PSScriptRoot -Filter "Get-*Drivers.ps1"

        # Launch all scrapers concurrently — each writes to its own subdirectory
        $scraperJobs = foreach ($script in $driverScripts) {
            Write-Host "    -> Launching $($script.Name)..."
            Start-ThreadJob -ScriptBlock {
                param($ScriptPath, $DlPath, $Arch)
                & $ScriptPath -DownloadPath $DlPath -Architecture $Arch
            } -ArgumentList $script.FullName, $driverTempPath, "x64" -Name $script.BaseName
        }

        # Wait for all scrapers with live status
        Write-Host "    -> Waiting for $($scraperJobs.Count) scrapers to complete..."
        $scraperJobs | Wait-Job | ForEach-Object {
            $job = $_
            if ($job.State -eq 'Failed') {
                Write-Warning "    [!] $($job.Name) failed: $($job.ChildJobs[0].JobStateInfo.Reason)"
            }
            else {
                Write-Host "    -> $($job.Name) completed." -ForegroundColor Green
            }
            Receive-Job $job
            Remove-Job $job
        }

        # Re-extract any nested CABs (some Update Catalog packages are double-wrapped)
        Write-Host ">>> Checking for nested CAB files..." -ForegroundColor Cyan
        $nestedCabs = Get-ChildItem -Path $driverTempPath -Filter *.cab -Recurse
        foreach ($cab in $nestedCabs) {
            $cabExtractDir = Join-Path $cab.DirectoryName $cab.BaseName
            if (-not (Test-Path $cabExtractDir)) { New-Item -ItemType Directory -Path $cabExtractDir -Force | Out-Null }
            Write-Host "    -> Re-extracting nested: $($cab.Name)"
            Start-Process "expand.exe" -ArgumentList "-F:* `"$($cab.FullName)`" `"$cabExtractDir`"" -Wait -NoNewWindow -PassThru | Out-Null
            Remove-Item $cab.FullName -Force
        }

        Write-Host ">>> Injecting Drivers into Offline Image..." -ForegroundColor Cyan
        dism.exe /Image:$winDrivePath /Add-Driver /Driver:$driverTempPath /Recurse /LogPath:$dismLogPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DISM /Add-Driver completed with exit code $LASTEXITCODE. Some drivers may have been skipped. Check log: $dismLogPath"
        }

        Write-Host ">>> Cleaning up Driver Temp Path..."
        Remove-Item -Path $driverTempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($Updates) {
        Write-Host ">>> Executing Updates Scraper..." -ForegroundColor Cyan
        $win11Version = "25H2"
        if ($IsoPath -match "Win11_([0-9]{2}H[0-9])_") {
            $win11Version = $matches[1]
        }

        $updatesTempPath = Join-Path $env:TEMP "Win11Updates_$(Get-Random)"
        $updateScript = Join-Path $PSScriptRoot "Get-Win11CumulativeUpdates.ps1"
        if (Test-Path $updateScript) {
            Write-Host "    -> Running Get-Win11CumulativeUpdates.ps1 (Targeting $win11Version)..."
            & $updateScript -Version $win11Version -DownloadPath $updatesTempPath

            $packages = Get-ChildItem -Path $updatesTempPath -Include *.msu, *.cab -Recurse
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
                dism.exe /Image:$winDrivePath /Add-Package /PackagePath:$updatesTempPath /ScratchDir:$dismScratchDir /LogPath:$dismLogPath
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

    Write-Host ">>> Writing Boot Files (BCDBoot)..." -ForegroundColor Cyan
    $winDir = Join-Path $winDrivePath "Windows"
    & bcdboot "$winDir" /s "$efiDrivePath" /f UEFI
    if ($LASTEXITCODE -ne 0) {
        throw "BCDBoot failed with exit code $LASTEXITCODE"
    }

    Write-Host ">>> Enabling Verbose SOS Mode and Boot Logging..." -ForegroundColor Cyan
    $bcdStore = Join-Path $efiDrivePath "EFI\Microsoft\Boot\BCD"
    & bcdedit /store "$bcdStore" /set '{default}' sos on
    & bcdedit /store "$bcdStore" /set '{default}' bootlog yes
    & bcdedit /store "$bcdStore" /set '{globalsettings}' bootuxdisabled on
    & bcdedit /store "$bcdStore" /set '{default}' recoveryenabled no

    Write-Host ">>> Injecting iSCSI and Network Boot Settings..." -ForegroundColor Cyan
    # Load the offline SYSTEM registry hive directly from the applied image
    $sysHivePath = Join-Path $winDir "System32\config\SYSTEM"
    $tempHiveName = "VHDX_Temp_SYSTEM"

    reg load "HKLM\$tempHiveName" "$sysHivePath" | Out-Null

    # Determine which control sets exist for mirroring
    $controlSets = @("ControlSet001")
    if (Test-Path "HKLM:\$tempHiveName\ControlSet002") {
        $controlSets += "ControlSet002"
    }

    foreach ($cs in $controlSets) {
        Write-Host "  Configuring $cs..." -ForegroundColor DarkGray

        # 1. Core iSCSI and Network Stack Services (Universally Required)
        $coreServices = @("MSiSCSI", "iScsiPrt", "iscsi", "NDIS", "Tcpip", "NetBT", "Winsock", "netfs")
        foreach ($service in $coreServices) {
            $regPath = "HKLM:\$tempHiveName\$cs\Services\$service"
            if (Test-Path $regPath) {
                Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
                Set-ItemProperty -Path $regPath -Name "BootFlags" -Value 1 -Type DWord
                Write-Host "  Promoted Core Stack: $service"
            }
        }

        # 2. Storage and Volume Management (Critical for VHDX/iSCSI)
        $storageServices = @(
            "vhdmp",      # VHD Miniport Driver — required since this IS a VHDX
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
            @{ Service = "ice"; Sys = "ice.sys" }             # E810 100GbE

            # --- Intel Ethernet (in-box MSFT) ---
            @{ Service = "e1i68x64"; Sys = "e1i68x64.sys" }        # I217/I218 1GbE
            @{ Service = "e2f68"; Sys = "e2f68.sys" }           # I225 (older gen) 2.5GbE
            @{ Service = "e1yexpress"; Sys = "e1y60x64.sys" }        # PRO/1000 CT/GT
            @{ Service = "KillerEth"; Sys = "e2xw10x64.sys" }       # Killer E2x00/E3x00

            # --- Realtek PCIe (injected via Get-RealtekEthernetDrivers.ps1) ---
            @{ Service = "rt25cx21x64"; Sys = "rt25cx21x64.sys" }     # RTL8125 2.5GbE
            @{ Service = "rt640x64"; Sys = "rt640x64.sys" }        # RTL8126 2.5GbE
            @{ Service = "rt27cx21x64"; Sys = "rt27cx21x64.sys" }     # RTL8127 10GbE
            @{ Service = "rt68cx21x64"; Sys = "rt68cx21x64.sys" }     # RTL8168 1GbE

            # --- Realtek USB (injected via Get-RealtekEthernetDrivers.ps1) ---
            @{ Service = "rtu53cx22x64"; Sys = "rtu53cx22x64.sys" }    # RTL8153 USB 1GbE
            @{ Service = "rtu56cx22x64"; Sys = "rtu56cx22x64.sys" }    # RTL8156 USB 2.5GbE
            @{ Service = "rtucx22x64"; Sys = "rtucx22x64.sys" }      # RTL8157/8159 USB 5G/10G

            # --- Realtek (in-box MSFT) ---
            @{ Service = "rtucx21x64"; Sys = "rtucx21x64.sys" }      # Realtek USB (in-box)
            @{ Service = "rtux64w10"; Sys = "rtux64w10.sys" }       # Realtek USB (legacy in-box)
            @{ Service = "RTL8023x64"; Sys = "Rtnic64.sys" }         # Realtek FE (legacy in-box)

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

            # --- USB Ethernet Adapters (in-box MSFT) ---
            @{ Service = "AX88179"; Sys = "ax88179_178a.sys" }    # ASIX USB 3.0 GbE
            @{ Service = "AX88772"; Sys = "ax88772.sys" }         # ASIX USB 2.0 FE
            @{ Service = "msux64w10"; Sys = "msux64w10.sys" }       # Samsung/Realtek USB GbE
            @{ Service = "LAN7800"; Sys = "lan7800-x64-n650f.sys" } # Microchip USB-C GbE

            # --- JMicron (in-box MSFT) ---
            @{ Service = "NETJME"; Sys = "NETJME.sys" }          # JMC250/JMC260
        )

        $driverStorePath = Join-Path $winDrivePath "Windows\System32\DriverStore\FileRepository"
        $bootDriverDir = Join-Path $winDrivePath "Windows\System32\drivers"

        foreach ($def in $nicDriverDefs) {
            $svcName = $def.Service
            $sysName = $def.Sys
            $regPath = "HKLM:\$tempHiveName\$cs\Services\$svcName"

            if (Test-Path $regPath) {
                # In-box driver with existing service entry — promote to boot-start
                Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
                Set-ItemProperty -Path $regPath -Name "BootFlags" -Value 1 -Type DWord
                Write-Host "  Promoted NIC Driver: $svcName (in-box)"
            }
            else {
                # Find .sys in DriverStore, copy to System32\drivers, create service entry
                $sysFile = Get-ChildItem -Path $driverStorePath -Filter $sysName -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1

                if ($sysFile) {
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
                }
                # else: driver not in image, silently skip
            }
        }

        # 4. SAN Policy — OfflineInternal (4): bring iSCSI boot disk online, leave others offline
        $partmgrParamsPath = "HKLM:\$tempHiveName\$cs\Services\partmgr\Parameters"
        if (-not (Test-Path $partmgrParamsPath)) { New-Item -Path $partmgrParamsPath -Force | Out-Null }
        Set-ItemProperty -Path $partmgrParamsPath -Name "SanPolicy" -Value 4 -Type DWord
        Write-Host "  Set SAN Policy: OfflineInternal (4)"

        # 5. TCPIP wait for network — give iSCSI time to establish
        $tcpipRegPath = "HKLM:\$tempHiveName\$cs\Services\Tcpip\Parameters"
        if (Test-Path $tcpipRegPath) {
            Set-ItemProperty -Path $tcpipRegPath -Name "PollBootPartitionTimeout" -Value 30000 -Type DWord
        }

        # 6. Disable BitLocker automatic device encryption
        $bitLockerRegPath = "HKLM:\$tempHiveName\$cs\Control\BitLocker"
        if (-not (Test-Path $bitLockerRegPath)) { New-Item -Path $bitLockerRegPath -Force | Out-Null }
        Set-ItemProperty -Path $bitLockerRegPath -Name "PreventDeviceEncryption" -Value 1 -Type DWord
    }
    Write-Host "Disabled BitLocker automatic device encryption"

    # Bypass TPM/SecureBoot/RAM checks (LabConfig) — not per-ControlSet
    $labConfigPath = "HKLM:\$tempHiveName\Setup\LabConfig"
    if (-not (Test-Path $labConfigPath)) { New-Item -Path $labConfigPath -Force | Out-Null }
    Set-ItemProperty -Path $labConfigPath -Name "BypassTPMCheck" -Value 1 -Type DWord
    Set-ItemProperty -Path $labConfigPath -Name "BypassSecureBootCheck" -Value 1 -Type DWord
    Set-ItemProperty -Path $labConfigPath -Name "BypassRAMCheck" -Value 1 -Type DWord
    Set-ItemProperty -Path $labConfigPath -Name "BypassStorageCheck" -Value 1 -Type DWord
    Write-Host "Injected LabConfig bypasses for TPM/RAM/SecureBoot"

    # Ensure registry finishes writing
    [gc]::collect()
    Start-Sleep -Seconds 2
    reg unload "HKLM\$tempHiveName"

    Write-Host ">>> Injecting OOBE Settings into Offline SOFTWARE Registry..." -ForegroundColor Cyan
    $softHivePath = Join-Path $winDir "System32\config\SOFTWARE"
    $tempSoftName = "VHDX_Temp_SOFTWARE"
    reg load "HKLM\$tempSoftName" "$softHivePath"

    # Remove requirement for an online Microsoft account (BypassNRO)
    $oobeRegPath = "HKLM:\$tempSoftName\Microsoft\Windows\CurrentVersion\OOBE"
    if (-not (Test-Path $oobeRegPath)) { New-Item -Path $oobeRegPath -Force | Out-Null }
    Set-ItemProperty -Path $oobeRegPath -Name "BypassNRO" -Value 1 -Type DWord
    Write-Host "Injected BypassNRO (Skip Microsoft Account)"

    [gc]::collect()
    Start-Sleep -Seconds 2
    reg unload "HKLM\$tempSoftName"

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
    Write-Error $_.Exception.Message
}
finally {
    # Ensure cleanup runs
    if ($isoImage) {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }
    if ($mountedVhd) {
        Dismount-VHD -Path $OutPath | Out-Null
    }
}

if ($success) {
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host " VHDX Creation Complete: $OutPath" -ForegroundColor Green
    Write-Host " Place this file in your iSCSI Target directory, or in"
    Write-Host " /srv/http/pxe/win11/ as backstore and configure"
    Write-Host " update-pxe-images.sh appropriately."
    Write-Host "==========================================================" -ForegroundColor Green
}
else {
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " VHDX Creation Failed!" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
}
