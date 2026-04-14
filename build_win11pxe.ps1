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

    Write-Host ">>> Applying Windows Image (Index $ImageIndex) from $wimPath to VHDX..." -ForegroundColor Cyan
    # Using DISM to apply the image
    dism.exe /Apply-Image /ImageFile:$wimPath /Index:$ImageIndex /ApplyDir:$winDrivePath

    Write-Host ">>> Writing Boot Files (BCDBoot)..." -ForegroundColor Cyan
    $winDir = Join-Path $winDrivePath "Windows"
    & bcdboot "$winDir" /s "$efiDrivePath" /f UEFI

    Write-Host ">>> Enabling Verbose SOS Mode and Boot Logging..." -ForegroundColor Cyan
    $bcdStore = Join-Path $efiDrivePath "EFI\Microsoft\Boot\BCD"
    & bcdedit /store "$bcdStore" /set '{default}' sos on
    & bcdedit /store "$bcdStore" /set '{default}' bootlog yes
    & bcdedit /store "$bcdStore" /set '{default}' quietboot off
    & bcdedit /store "$bcdStore" /set '{default}' noguiboot yes
    & bcdedit /store "$bcdStore" /set '{default}' recoveryenabled no

    Write-Host ">>> Injecting iSCSI and Network Boot Settings..." -ForegroundColor Cyan
    # Load the offline SYSTEM registry hive directly from the applied image
    $sysHivePath = Join-Path $winDir "System32\config\SYSTEM"
    $tempHiveName = "VHDX_Temp_SYSTEM"
    
    reg load "HKLM\$tempHiveName" "$sysHivePath" | Out-Null

    # 1. Core iSCSI and Network Stack Services (Universally Required)
    $coreServices = @("MSiSCSI", "iScsiPrt", "iscsi", "NDIS", "Tcpip", "netfs")
    foreach ($service in $coreServices) {
        $regPath = "HKLM:\$tempHiveName\ControlSet001\Services\$service"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
            Set-ItemProperty -Path $regPath -Name "BootFlags" -Value 1 -Type DWord
            Write-Host "Promoted Core Stack: $service"
        }
    }

    # 2. Targeted Virtual, Enterprise & Prosumer NIC Drivers
    $nicDrivers = @(
        # --- Virtual Ethernet ---
        "netvsc",                 # Hyper-V Virtual Ethernet
        "netkvm",                 # VirtIO Ethernet

        # --- 2.5GbE, 5GbE, & 10GbE Prosumer/Workstation ---
        "e2fexpress",             # Intel 2.5GbE (I225-V / I226-V)
        "rt640x64",               # Realtek PCIe 1G/2.5G/5G/10G (RTL8125, RTL8126, RTL8127)
        "rtump64x64", "rtux64w10",# Realtek USB 2.5G/5G/10G (RTL8156, RTL8157, RTL8159)
        "rtnetcx",                # Realtek NetAdapterCx (Next-Gen Windows 11 Driver)
        "aqnic650", "aqnic",      # Marvell/Aquantia 2.5/5/10GbE (AQC107 / AQC113)

        # --- 10/40/100GbE Enterprise ---
        "mlx5", "mlx4eth",        # Mellanox ConnectX-3, 4, 5, 6
        "ixgbe", "ixgben", "ixv", # Intel 10GbE (82599/X540)
        "i40ea", "i40eb",         # Intel 10/40GbE (X710/XL710)
        "ice",                    # Intel 100GbE (E810 series)
        "qfle3", "qevb", "bxvbd", # QLogic/Broadcom NetXtreme and FastLinQ
        "cxgb4",                  # Chelsio 10/40GbE

        # --- Standard 1GbE Fallbacks ---
        "e1dexpress",             # Intel 1GbE (I219-V / I211-AT)
        "e1r68x64"                # Intel 1GbE (I210)
    )

    foreach ($driver in $nicDrivers) {
        $regPath = "HKLM:\$tempHiveName\ControlSet001\Services\$driver"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name "Start" -Value 0 -Type DWord
            Set-ItemProperty -Path $regPath -Name "BootFlags" -Value 1 -Type DWord
            Write-Host "Promoted NIC Driver: $driver"
        }
    }

    # Optional: Enable TCPIP wait for network
    $tcpipRegPath = "HKLM:\$tempHiveName\ControlSet001\Services\Tcpip\Parameters"
    if (Test-Path $tcpipRegPath) {
        Set-ItemProperty -Path $tcpipRegPath -Name "PollBootPartitionTimeout" -Value 30000 -Type DWord
    }

    # Disable BitLocker automatic device encryption
    $bitLockerRegPath = "HKLM:\$tempHiveName\ControlSet001\Control\BitLocker"
    if (-not (Test-Path $bitLockerRegPath)) { New-Item -Path $bitLockerRegPath -Force | Out-Null }
    Set-ItemProperty -Path $bitLockerRegPath -Name "PreventDeviceEncryption" -Value 1 -Type DWord
    Write-Host "Disabled BitLocker automatic device encryption"

    # Bypass TPM/SecureBoot/RAM checks (LabConfig)
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
    $setupCompletePath = Join-Path $setupScriptsPath "SetupComplete.cmd"
    $cmdContent = '@echo off
schtasks /create /f /ru SYSTEM /sc onstart /tn "DisableNetPower" /tr "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -Command ''Get-NetAdapter | Set-NetAdapterPowerManagement -AllowComputerToTurnOffDevice $false''"
powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Set-NetAdapterPowerManagement -AllowComputerToTurnOffDevice $false"
del "%~f0"
'
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
