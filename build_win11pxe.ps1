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
    [long]$SizeBytes = 64GB,

    [Parameter(Mandatory = $false)]
    [int]$ImageIndex = 6 # Windows 11 Pro is typically index 6 on standard media
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

    # Recommended UEFI partition layout
    Write-Host ">>> Creating EFI Partition..." -ForegroundColor Cyan
    $efiPartition = New-Partition -DiskNumber $diskNumber -Size 100MB -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
    $efiVolume = Format-Volume -Partition $efiPartition -FileSystem FAT32 -NewFileSystemLabel "System"

    Write-Host ">>> Creating MSR Partition..." -ForegroundColor Cyan
    New-Partition -DiskNumber $diskNumber -Size 16MB -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" | Out-Null

    Write-Host ">>> Creating Windows Partition..." -ForegroundColor Cyan
    $winPartition = New-Partition -DiskNumber $diskNumber -UseMaximumSize
    $winVolume = Format-Volume -Partition $winPartition -FileSystem NTFS -NewFileSystemLabel "Windows"

    $efiDrivePath = "\\?\Volume{$($efiVolume.ObjectId.Split('{}')[1])}\"
    $winDrivePath = "\\?\Volume{$($winVolume.ObjectId.Split('{}')[1])}\"

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

    Write-Host ">>> Applying Windows Image (Index $ImageIndex) from $wimPath to VHDX..." -ForegroundColor Cyan
    # Using DISM to apply the image
    dism.exe /Apply-Image /ImageFile:$wimPath /Index:$ImageIndex /ApplyDir:$winDrivePath

    Write-Host ">>> Writing Boot Files (BCDBoot)..." -ForegroundColor Cyan
    $winDir = Join-Path $winDrivePath "Windows"
    & bcdboot "$winDir" /s "$efiDrivePath" /f UEFI

    Write-Host ">>> Injecting iSCSI Boot Settings into Offline Registry..." -ForegroundColor Cyan
    # Load the offline SYSTEM registry hive directly from the applied image
    $sysHivePath = Join-Path $winDir "System32\config\SYSTEM"
    $tempHiveName = "VHDX_Temp_SYSTEM"
    
    reg load "HKLM\$tempHiveName" "$sysHivePath"

    # Set MSiSCSI service to start at boot (Start = 0)
    $scsiRegPath = "HKLM:\$tempHiveName\ControlSet001\Services\MSiSCSI"
    if (Test-Path $scsiRegPath) {
        Set-ItemProperty -Path $scsiRegPath -Name "Start" -Value 0 -Type DWord
        Write-Host "Set MSiSCSI Start to 0"
    }
    else {
        Write-Warning "Could not find MSiSCSI service in offline registry."
    }

    # Optional: Enable TCPIP wait for network
    $tcpipRegPath = "HKLM:\$tempHiveName\ControlSet001\Services\Tcpip\Parameters"
    if (Test-Path $tcpipRegPath) {
        Set-ItemProperty -Path $tcpipRegPath -Name "PollBootPartitionTimeout" -Value 30000 -Type DWord
    }

    # Ensure registry finishes writing
    [gc]::collect()
    Start-Sleep -Seconds 2
    reg unload "HKLM\$tempHiveName"

    Write-Host ">>> Done! Unmounting images..." -ForegroundColor Cyan
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

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " VHDX Creation Complete: $OutPath" -ForegroundColor Green
Write-Host " Place this file in your iSCSI Target directory, or in"
Write-Host " /srv/http/pxe/win11/ as backstore and configure"
Write-Host " update-pxe-images.sh appropriately."
Write-Host "==========================================================" -ForegroundColor Green
