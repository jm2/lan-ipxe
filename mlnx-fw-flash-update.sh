#!/bin/bash

# ==============================================================================
# Mellanox NIC Detection, Cross-Flashing & UEFI Config Tool (Open-Source)
# ==============================================================================

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "[-] Error: This script must be run as root."
   exit 1
fi

# Ensure mstflint (Open-Source Mellanox Firmware Tools) is installed
if ! command -v mstflint &> /dev/null || ! command -v mstconfig &> /dev/null; then
    echo "[-] Error: 'mstflint' or 'mstconfig' utility not found."
    echo "    Please install the open-source mstflint package."
    echo "    On Arch Linux, run: pacman -S mstflint"
    exit 1
fi

# Ensure PCI utilities are installed
if ! command -v lspci &> /dev/null; then
    echo "[-] Error: 'lspci' utility not found. Please install pciutils."
    exit 1
fi

echo "============================================================"
echo "      Mellanox NIC Detector & Cross-Flasher (mstflint)      "
echo "============================================================"
echo "[*] Scanning for Mellanox PCIe devices..."

# Find Mellanox PCI devices (Domain:Bus:Device.Function format)
DEVICES=$(lspci -D | grep -i "mellanox" | awk '{print $1}')

if [ -z "$DEVICES" ]; then
    echo "[-] No Mellanox NICs found on this system."
    exit 0
fi

declare -A DEV_PN
declare -A DEV_PSID
declare -A DEV_FW
declare -a DEV_ARRAY

i=1
for dev in $DEVICES; do
    echo "------------------------------------------------------------"
    echo "[$i] PCI Device: $dev"
    
    # Query the device using mstflint
    QUERY_OUTPUT=$(mstflint -d "$dev" query 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        PN=$(echo "$QUERY_OUTPUT" | grep -E "Part Number:" | awk '{print $3}')
        PSID=$(echo "$QUERY_OUTPUT" | grep -E "PSID:" | awk '{print $2}')
        FW=$(echo "$QUERY_OUTPUT" | grep -E "FW Version:" | awk '{print $3}')
        
        DEV_PN[$i]=$PN
        DEV_PSID[$i]=$PSID
        DEV_FW[$i]=$FW
        DEV_ARRAY[$i]=$dev
        
        echo "    Part Number:   $PN"
        echo "    PSID:          $PSID"
        echo "    FW Version:    $FW"
        
        # Basic OEM detection based on PSID prefix
        if [[ "$PSID" == MT_* ]]; then
            echo "    Status:        Standard Mellanox Firmware detected."
        else
            echo "    Status:        OEM Firmware detected (Cross-flash candidate)."
        fi
    else
         echo "    [-] Could not query device with mstflint."
         echo "        Ensure the device is not hung and you have proper PCI access."
         DEV_ARRAY[$i]=$dev
    fi
    ((i++))
done

echo "------------------------------------------------------------"
read -p "Select a device to process (1-$((${#DEV_ARRAY[@]}))) or 'q' to quit: " CHOICE

if [[ "$CHOICE" == "q" ]]; then
    echo "Exiting..."
    exit 0
fi

if [[ -z "${DEV_ARRAY[$CHOICE]}" ]]; then
    echo "[-] Invalid selection."
    exit 1
fi

TARGET_DEV="${DEV_ARRAY[$CHOICE]}"
TARGET_PN="${DEV_PN[$CHOICE]}"
TARGET_PSID="${DEV_PSID[$CHOICE]}"

echo ""
echo "============================================================"
echo "                   FIRMWARE DOWNLOAD GUIDE                  "
echo "============================================================"
echo "To cross-flash this card, you need the correct stock Mellanox .bin file."
echo "1. Go to the KCORES Reference List to find the Mellanox equivalent Part Number:"
echo "   --> https://github.com/KCORES/100g.kcores.com/blob/main/DOCUMENTS/Mellanox(NVIDIA)-nic-list-en.md"
echo ""
echo "2. Once you have the target Mellanox PN (e.g., MCX4121A-ACAT), download the archive:"
echo "   --> https://network.nvidia.com/support/firmware/firmware-downloads/"
echo ""
echo "3. Extract the downloaded .zip archive. Inside, you will find a .bin file."
echo "============================================================"
echo ""

read -p "Do you have the path to your new firmware .bin file ready? (y/n/skip to uefi): " HAS_FILE
if [[ "$HAS_FILE" == "skip" || "$HAS_FILE" == "s" ]]; then
    echo "[*] Skipping firmware flash..."
elif [[ "$HAS_FILE" == "y" || "$HAS_FILE" == "Y" ]]; then

    read -p "Enter the full path to the firmware .bin file: " BIN_PATH

    if [ ! -f "$BIN_PATH" ]; then
        echo "[-] Error: File not found at $BIN_PATH"
        exit 1
    fi

    echo ""
    echo "============================================================"
    echo "                    !!! WARNING !!!                         "
    echo "============================================================"
    echo "Target PCI Device:  $TARGET_DEV"
    echo "Current PSID:       $TARGET_PSID"
    echo "Current Part Num:   $TARGET_PN"
    echo "Image to flash:     $BIN_PATH"
    echo ""
    echo "You are about to flash new firmware to this network card."
    echo "Because you are cross-flashing, this process will use the "
    echo "-allow_psid_change flag to overwrite the OEM restrictions."
    echo "Interrupting this process or flashing the wrong architecture"
    echo "WILL brick the network card."
    echo "============================================================"
    read -p "Are you ABSOLUTELY sure you want to proceed? Type 'YES' in all caps to burn: " CONFIRM

    if [[ "$CONFIRM" == "YES" ]]; then
        echo "[*] Initiating firmware burn with PSID override..."
        
        mstflint -d "$TARGET_DEV" -i "$BIN_PATH" -allow_psid_change -allow_rom_change burn
        
        if [ $? -eq 0 ]; then
            echo "[+] Flash successful!"
        else
            echo "[-] Flash failed. Check the error output above."
            exit 1
        fi
    else
        echo "Flash operation aborted by user."
    fi
else
    echo "Exiting."
    exit 0
fi

echo ""
echo "============================================================"
echo "                  UEFI PXE CONFIGURATION                    "
echo "============================================================"
read -p "Would you like to configure this card for UEFI PXE boot now? (y/n): " DO_UEFI

if [[ "$DO_UEFI" == "y" || "$DO_UEFI" == "Y" ]]; then
    echo "[*] Applying mstconfig UEFI settings to $TARGET_DEV..."
    # The -y flag answers yes to the mstconfig confirmation prompt
    mstconfig -y -d "$TARGET_DEV" set \
        EXP_ROM_UEFI_x86_ENABLE=1 \
        EXP_ROM_UEFI_ARM_ENABLE=0 \
        UEFI_HII_EN=1 \
        EXP_ROM_PXE_ENABLE=0 \
        LEGACY_BOOT_PROTOCOL=0
        
    if [ $? -eq 0 ]; then
        echo "[+] UEFI configuration applied successfully."
    else
        echo "[-] Failed to apply UEFI configuration."
    fi
fi

echo ""
echo "[!] A complete system reboot (or 'mstfwreset') is required for the new firmware and configurations to take effect."
