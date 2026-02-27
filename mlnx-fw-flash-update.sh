#!/bin/bash

# ==============================================================================
# Mellanox Smart NIC Detector, Cross-Flasher & UEFI Config Tool
# ==============================================================================

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "[-] Error: This script must be run as root."
   exit 1
fi

# Ensure mstflint is installed
if ! command -v mstflint &> /dev/null || ! command -v mstconfig &> /dev/null; then
    echo "[-] Error: 'mstflint' or 'mstconfig' utility not found."
    echo "    On Arch Linux, run: pacman -S mstflint"
    exit 1
fi

# Ensure lspci is available to find the initial devices
if ! command -v lspci &> /dev/null; then
    echo "[-] Error: 'lspci' utility not found. Please install pciutils."
    exit 1
fi

# --- Helper Functions ---

get_mlx_family() {
    # Mellanox PCI Device IDs
    case "${1,,}" in
        "1003") echo "ConnectX-3" ;;
        "1007") echo "ConnectX-3 Pro" ;;
        "1013") echo "ConnectX-4" ;;
        "1015") echo "ConnectX-4 Lx" ;;
        "1017") echo "ConnectX-5" ;;
        "1019") echo "ConnectX-5 Ex" ;;
        "101b") echo "ConnectX-6" ;;
        "101d") echo "ConnectX-6 Dx" ;;
        "101f") echo "ConnectX-6 Lx" ;;
        "1021") echo "ConnectX-7" ;;
        "1023") echo "BlueField-3" ;;
        "a2d2"|"a2d6") echo "BlueField-2" ;;
        *) echo "Unknown Mellanox Silicon (ID: $1)" ;;
    esac
}

get_oem_from_psid() {
    local psid="$1"
    if [[ "$psid" == MT_* ]]; then echo "Mellanox / NVIDIA (Standard)"
    elif [[ "$psid" == DEL* ]]; then echo "Dell OEM"
    elif [[ "$psid" == HP_* || "$psid" == HPE* ]]; then echo "HPE OEM"
    elif [[ "$psid" == LEN* ]]; then echo "Lenovo OEM"
    elif [[ "$psid" == SM_* || "$psid" == SMC* ]]; then echo "Supermicro OEM"
    elif [[ "$psid" == IBM* ]]; then echo "IBM OEM"
    elif [[ "$psid" == CYS* || "$psid" == CIS* ]]; then echo "Cisco OEM"
    elif [[ "$psid" == FS_* ]]; then echo "FS.com OEM"
    elif [[ "$psid" == VMD* || "$psid" == GIG* ]]; then echo "Gigabyte OEM"
    else echo "Unknown OEM (Requires KCORES manual lookup)"
    fi
}

# --- Main Logic ---

echo "============================================================"
echo "    Mellanox Smart Detector & Cross-Flasher (mstflint)      "
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
declare -a DEV_ARRAY

i=1
for dev in $DEVICES; do
    echo "------------------------------------------------------------"
    echo "[$i] PCI Address: $dev"
    
    # Read Device ID directly from Linux sysfs (fastest and most reliable)
    if [ -f "/sys/bus/pci/devices/$dev/device" ]; then
        SYSFS_DEV_ID=$(cat "/sys/bus/pci/devices/$dev/device" | sed 's/0x//')
        HW_FAMILY=$(get_mlx_family "$SYSFS_DEV_ID")
    else
        HW_FAMILY="Unknown (Sysfs error)"
    fi
    
    # Query the device using mstflint
    QUERY_OUTPUT=$(mstflint -d "$dev" query 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        PN=$(echo "$QUERY_OUTPUT" | grep -E "Part Number:" | awk '{print $3}')
        PSID=$(echo "$QUERY_OUTPUT" | grep -E "PSID:" | awk '{print $2}')
        FW=$(echo "$QUERY_OUTPUT" | grep -E "FW Version:" | awk '{print $3}')
        OEM=$(get_oem_from_psid "$PSID")
        
        DEV_PN[$i]=$PN
        DEV_PSID[$i]=$PSID
        DEV_ARRAY[$i]=$dev
        
        echo "    Hardware:      $HW_FAMILY"
        echo "    OEM Vendor:    $OEM"
        echo "    Part Number:   $PN"
        echo "    PSID:          $PSID"
        echo "    FW Version:    $FW"
        
        if [[ "$PSID" == MT_* ]]; then
            echo "    Action:        Ready for standard FW updates."
        else
            echo "    Action:        Cross-flash candidate (-allow_psid_change required)."
        fi
    else
         echo "    [-] Could not query device firmware with mstflint."
         echo "    Hardware:      $HW_FAMILY"
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
TARGET_DEV_ID=$(cat "/sys/bus/pci/devices/$TARGET_DEV/device" | sed 's/0x//')
TARGET_FAMILY=$(get_mlx_family "$TARGET_DEV_ID")
TARGET_OEM=$(get_oem_from_psid "$TARGET_PSID")

echo ""
echo "============================================================"
echo "                   FIRMWARE DOWNLOAD GUIDE                  "
echo "============================================================"
echo "Card Identified as: $TARGET_OEM $TARGET_FAMILY"
echo ""
echo "To cross-flash this card, you need the correct stock Mellanox .bin file."
echo "CRITICAL: The new firmware MUST match the $TARGET_FAMILY hardware architecture."
echo ""
echo "1. Go to the KCORES Reference List to find the Mellanox equivalent Part Number:"
echo "   --> https://github.com/KCORES/100g.kcores.com/blob/main/DOCUMENTS/Mellanox(NVIDIA)-nic-list-en.md"
echo "2. Download the archive for the mapped KCORES Part Number:"
echo "   --> https://network.nvidia.com/support/firmware/firmware-downloads/"
echo "3. Extract the downloaded .zip archive to locate the .bin file."
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

    echo "[*] Validating firmware image..."
    IMAGE_QUERY=$(mstflint -i "$BIN_PATH" query 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "[-] Error: $BIN_PATH is not a valid Mellanox firmware image, or cannot be read."
        exit 1
    fi

    IMAGE_PSID=$(echo "$IMAGE_QUERY" | grep -E "PSID:" | head -n 1 | awk '{print $2}')
    IMAGE_FW=$(echo "$IMAGE_QUERY" | grep -E "FW Version:" | awk '{print $3}')

    if [ -z "$IMAGE_PSID" ]; then
        echo "[-] Error: Could not extract PSID from the provided image. Aborting."
        exit 1
    fi

    echo ""
    echo "============================================================"
    echo "                    FIRMWARE VALIDATION                     "
    echo "============================================================"
    echo "Target Device:      $TARGET_DEV ($TARGET_FAMILY)"
    echo "Current OEM:        $TARGET_OEM"
    echo "Current PSID:       $TARGET_PSID"
    echo "Image PSID:         $IMAGE_PSID"
    echo "Image FW Version:   $IMAGE_FW"
    echo "============================================================"

    # Determine if we are cross-flashing or doing a standard update
    FLASH_CMD="mstflint -d \"$TARGET_DEV\" -i \"$BIN_PATH\""
    IS_CROSSFLASH=0

    if [[ "$TARGET_PSID" == "$IMAGE_PSID" ]]; then
        echo "[+] Standard Update Detected (PSIDs match)."
        FLASH_CMD="$FLASH_CMD burn"
    else
        echo "[!] CROSS-FLASH DETECTED (PSID mismatch)."
        echo "    The script forces -allow_psid_change and -allow_rom_change."
        echo "    WARNING: If this image is not meant for a $TARGET_FAMILY architecture, "
        echo "    it WILL brick the network card!"
        FLASH_CMD="$FLASH_CMD -allow_psid_change -allow_rom_change burn"
        IS_CROSSFLASH=1
    fi

    echo ""
    read -p "Are you ABSOLUTELY sure you want to proceed? Type 'YES' in all caps to burn: " CONFIRM

    if [[ "$CONFIRM" == "YES" ]]; then
        echo "[*] Initiating firmware burn..."
        
        # Eval is used here to parse the constructed string properly
        eval $FLASH_CMD
        
        if [ $? -eq 0 ]; then
            echo "[+] Flash successful!"
            
            # Further automation: Prompt to reset device immediately
            read -p "Would you like to reset the NIC firmware now (avoids system reboot)? (y/n): " DO_RESET
            if [[ "$DO_RESET" == "y" || "$DO_RESET" == "Y" ]]; then
                echo "[*] Resetting firmware on $TARGET_DEV..."
                mstfwreset -d "$TARGET_DEV" -y reset
            fi
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
echo "[!] A complete system reboot (or 'mstfwreset -d $TARGET_DEV -y reset') is required for changes to take effect."