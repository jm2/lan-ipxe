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
    elif [[ "$psid" == LEN* || "$psid" == LNV* ]]; then echo "Lenovo OEM"
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
# We use awk to filter by Domain:Bus:Device so multi-port cards appear as a single entry
DEVICES=$(lspci -D | grep -i "mellanox" | awk '{print $1}' | awk -F'.' '!seen[$1]++')

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
    
    # Query the device using mstflint (use 'query full' to reliably capture Part Number)
    QUERY_OUTPUT=$(mstflint -d "$dev" query full 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        # PN might have extra spaces or be on the same line as the label, use sed to strip the label and retain the rest
        PN=$(echo "$QUERY_OUTPUT" | grep -iE "Part Number:" | sed 's/^[ \t]*Part Number:[ \t]*//')
        PSID=$(echo "$QUERY_OUTPUT" | grep -E "PSID:" | awk '{print $2}')
        FW=$(echo "$QUERY_OUTPUT" | grep -E "FW Version:" | awk '{print $3}')
        OEM=$(get_oem_from_psid "$PSID")
        
        DEV_PN[$i]=$PN
        DEV_PSID[$i]=$PSID
        DEV_FW[$i]=$FW
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
TARGET_FW="${DEV_FW[$CHOICE]}"
TARGET_DEV_ID=$(cat "/sys/bus/pci/devices/$TARGET_DEV/device" | sed 's/0x//')
TARGET_FAMILY=$(get_mlx_family "$TARGET_DEV_ID")
TARGET_OEM=$(get_oem_from_psid "$TARGET_PSID")

get_fw_url() {
    local pn="$1"
    local family="$2"
    
    # 1. Precise Match by Part Number (OPN)
    case "$pn" in
        "MCX75343AAS-NEA" | "MCX75510AAS-NEA" | "MCX753436MS-HEA" | "MCX755106AS-HEA" | "MCX75310AAS-NEA" | "MCX75510AAS-HEA" | "MCX713106AS-VEA" | "MCX713106AC-VEA" | "MCX713106AC-CEA" | "MCX713106AS-CEA" | "MCX75310AAS-HEA" | "MCX713104AS-ADA" | "MCX75210AAS-HEA" | "MCX75210AAS-NEA" | "MCX713104AC-ADA" | "MCX750500B-0D0K" | "MCX750500C-0D0K" | "MCX750500B-0D00" | "MCX750500C-0D00" | "MCX755206AS-NEA-N" | "MCX753436MC-HEA" | "MCX755106AC-HEA" | "MCX75310AAC-NEA" | "MCX713114TC-GEA" | "MCX75343AMS-NEAC" | "MCX75343AMC-NEAC" | "692-9X760-00SE-S00" | "692-9X760-00SE-S0C" | "MCX753436MS-HEB" | "MCX715105AS-WEAT" | "MCX753106AS-HEA-N" | "MCX75310AAS-HEA-N" | "P3740-B0-QSFP" | "900-24768-0002")
            echo "https://network.nvidia.com/support/firmware/connectx7/"
            ;;
        "MCX683105AN-HDA")
            echo "https://network.nvidia.com/support/firmware/connectx6de/"
            ;;
        "MCX631102AS-ADA" | "MCX631105AE-GDA" | "MCX631102AN-ADA" | "MCX631432AN-ADA" | "MCX631432AC-ADA" | "MCX631435AN-GDA" | "MCX631435AC-GDA" | "MCX631432AS-ADA" | "MCX631105AC-GDA" | "MCX631102AE-ADA" | "MCX631432AE-ADA" | "MCX631435AE-GDA" | "MCX631105AN-GDA" | "MCX631102AC-ADA")
            echo "https://network.nvidia.com/support/firmware/connectx6lx/"
            ;;
        "MCX623102AC-GDA" | "MCX623106PN-CDA" | "MCX623102AC-ADA" | "MCX623432AN-GDA" | "MCX623436AN-CDA" | "MCX623106AN-CDA" | "MCX623102AE-GDA" | "MCX623106TC-CDA" | "MCX623436MN-CDA" | "MCX623430MS-CDA" | "MCX623432MN-ADA" | "MCX621202AC-ADA" | "MCX623435AC-CDA" | "MCX623106AC-CDA" | "MCX623106AS-CDA" | "MCX623436AE-CDA" | "MCX623435AC-VDA" | "MCX621102AN-ADA" | "MCX623432AN-ADA" | "MCX623106PC-CDA" | "MCX623435AN-VDA" | "MCX621102AE-ADA" | "MCX623106PE-CDA" | "MCX623435AE-CDA" | "MCX623102AS-GDA" | "MCX623105AN-CDA" | "MCX623105AS-VDA" | "MCX623436AS-CDA" | "MCX623432AS-ADA" | "MCX623102AS-ADA" | "MCX623435AN-CDA" | "MCX623432AE-ADA" | "MCX623102AN-GDA" | "MCX623435MN-VDA" | "MCX623439MC-CDA" | "MCX623105AE-CDA" | "MCX623106GN-CDA" | "MCX623432AC-GDA" | "MCX623405AN-CDA" | "MCX621102AC-ADA" | "MCX623105AN-VDA" | "MCX623106TS-CDA" | "MCX623436AC-CDA" | "MCX623105AC-VDA" | "MCX623435AS-VDA" | "MCX623432AS-GDA" | "MCX623106TN-CDA" | "MCX623106GC-CDA" | "MCX623436MS-CDA" | "MCX623432AC-ADA" | "MCX623405AC-CDA" | "MCX623435MN-CDA" | "MCX623106AE-CDA" | "MCX623105AE-VDA" | "MCX623105AC-CDA" | "MCX621202AS-ADA" | "MCX623102AN-ADA" | "MCX623405AN-VDA")
            echo "https://network.nvidia.com/support/firmware/connectx6dx/"
            ;;
        "MCX613105A-VDA" | "MCX614106A-VCA" | "MCX613106A-VDA" | "MCX614106A-CCA" | "MCX613106A-CCA" | "MCX614105A-VCA" | "MCX613436A-VDA")
            echo "https://network.nvidia.com/support/firmware/connectx6en/"
            ;;
        "MCX654106A-HCA" | "MCX653435A-HDA" | "MCX653435M-HDA" | "MCX653106A-HDA" | "MCX654105A-HCA" | "MCX653106A-ECA" | "MCX653436A-HDA" | "MCX653105A-ECA" | "MCX653105A-HDA" | "MCX653105A-EFA" | "MCX653435A-EDA" | "MCX654106A-ECA" | "MCX653106A-EFA" | "MCX651105A-EDA")
            echo "https://network.nvidia.com/support/firmware/connectx6ib/"
            ;;
        "MCX565M-CDA" | "MCX512A-ACA" | "MCX545A-CCU" | "MCX545B-CCU" | "MCX542A-ACA" | "MCX545B-GCU" | "MCX516A-CCA" | "MCX546A-CDAN" | "MCX542B-ACA" | "MCX516A-CCH" | "MCX512A-ADA" | "MCX562A-ACA" | "MCX511F-ACA" | "MCX546A-BCAN" | "MCX566A-CCA" | "MCX512F-ACA" | "MCX512F-ACH" | "MCX566A-CDA" | "MCX566M-GDA" | "MCX516A-BDA" | "MCX512A-ACU" | "MCX513A-GCH" | "MCX515A-CCU" | "MCX542B-ACU" | "MCX565A-CCA" | "MCX514A-GCH" | "MCX516A-GCA" | "MCX545A-CCA" | "MCX516A-CDA" | "MCX515A-CCA" | "MCX515A-GCA")
            echo "https://network.nvidia.com/support/firmware/connectx5en/"
            ;;
        "MCX556A-EDA" | "MCX545B-ECA" | "MCX555A-ECA" | "MCX556A-ECU" | "MCX553Q-ECA" | "MCX556A-ECA" | "MCX545M-ECA" | "MCX546A-EDAN" | "MCX556M-ECA" | "MCX545A-ECA")
            echo "https://network.nvidia.com/support/firmware/connectx5ib/"
            ;;
        "MCX4121A-XCA" | "MCX4121A-ACA" | "MCX4131A-GCA" | "MCX4411A-ACA" | "MCX4421A-ACQ" | "MCX4431A-GCU" | "MCX4411A-ACUN" | "MCX4421A-ACU" | "MCX4111A-ACA" | "MCX4131A-BCA" | "MCX4411A-ACQ" | "MCX4421A-ACA" | "MCX4121A-XCH" | "MCX4621A-XCA" | "MCX4621A-ACA" | "MCX4411A-ACH" | "MCX4121A-ACU" | "MCX4111A-ACUT" | "MCX4111A-XCA" | "MCX4421A-XCQ" | "MCX4421A-XCH" | "MCX4431A-GCA" | "MCX4431M-GCA" | "MCX4121A-ACH")
            echo "https://network.nvidia.com/support/firmware/connectx4lxen/"
            ;;
        "MCX414A-BCA" | "MCX416A-CCA" | "MCX413A-GCA" | "MCX414A-GCA" | "MCX413A-BCA")
            echo "https://network.nvidia.com/support/firmware/connectx4en/"
            ;;
        "MCX455A-FCA" | "MCX456A-ECA" | "MCX454A-FCA" | "MCX456A-FCA" | "MCX453A-FCA")
            echo "https://network.nvidia.com/support/firmware/connectx4ib/"
            ;;
        "MCX311A-XCCT" | "MCX312B-XCCT" | "MCX312C-XCCT" | "MCX313A-BCCT" | "MCX314A-BCCT" | "MCX341A-XCQN" | "MCX341A-XCPN" | "MCX342A-XCQN" | "MCX342A-XCPN" | "MCX345A-BCPN" | "MCX345A-BCQN" | "MCX346A-BCPN" | "MCX346A-BCQN")
            echo "https://network.nvidia.com/support/firmware/connectx3proen/"
            ;;
        "MCX353A-FCCT" | "MCX354A-FCCT")
            echo "https://network.nvidia.com/support/firmware/connectx3proib/"
            ;;
        "MCX311A-XCAT" | "MCX312A-XCBT" | "MCX312B-XCBT" | "MCX313A-BCBT" | "MCX314A-BCBT" | "MCX341A-XCGN" | "MCX342A-XCCN" | "MCX342A-XCGN" | "MCX341A-XCCN")
            echo "https://network.nvidia.com/support/firmware/connectx3en/"
            ;;
        "MCX353A-FCBT" | "MCX353A-QCBT" | "MCX353A-TCBT" | "MCX354A-FCBT" | "MCX354A-QCBT" | "MCX354A-TCBT")
            echo "https://network.nvidia.com/support/firmware/connectx3ib/"
            ;;
    esac
    
    # 2. Fallback Match by Family
    case "$family" in
        "ConnectX-3") echo "https://network.nvidia.com/support/firmware/connectx3ib/" ;;
        "ConnectX-3 Pro") echo "https://network.nvidia.com/support/firmware/connectx3proib/" ;;
        "ConnectX-4") echo "https://network.nvidia.com/support/firmware/connectx4ib/" ;;
        "ConnectX-4 Lx") echo "https://network.nvidia.com/support/firmware/connectx4lxen/" ;;
        "ConnectX-5") echo "https://network.nvidia.com/support/firmware/connectx5ib/" ;;
        "ConnectX-5 Ex") echo "https://network.nvidia.com/support/firmware/connectx5ib/" ;;
        "ConnectX-6") echo "https://network.nvidia.com/support/firmware/connectx6ib/" ;;
        "ConnectX-6 Dx") echo "https://network.nvidia.com/support/firmware/connectx6dx/" ;;
        "ConnectX-6 Lx") echo "https://network.nvidia.com/support/firmware/connectx6lx/" ;;
        "ConnectX-7") echo "https://network.nvidia.com/support/firmware/connectx7/" ;;
        *) echo "https://network.nvidia.com/support/firmware/firmware-downloads/" ;;
    esac
}

NVIDIA_URL=$(get_fw_url "$TARGET_PN" "$TARGET_FAMILY")

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
echo "2. Download the archive from NVIDIA for $TARGET_FAMILY:"
echo "   --> $NVIDIA_URL"
echo "3. Extract the downloaded .zip archive to locate the .bin file."
echo "============================================================"
echo ""

read -p "Paste the direct URL to the firmware .zip file (or type 'skip' to go to UEFI): " FW_URL
if [[ "$FW_URL" == "skip" || "$FW_URL" == "s" ]]; then
    echo "[*] Skipping firmware flash..."
elif [[ "$FW_URL" =~ ^https?:// ]]; then

    # Create a temporary working directory
    TMP_DIR=$(mktemp -d -t mlnx_fw_XXXXXX)
    echo "[*] Created temporary working directory: $TMP_DIR"
    
    ZIP_PATH="$TMP_DIR/firmware.zip"
    echo "[*] Downloading firmware archive from NVIDIA..."
    
    # Download the file, following redirects (-L) and showing a progress bar (-#)
    curl -L -# -o "$ZIP_PATH" "$FW_URL"
    
    if [ ! -f "$ZIP_PATH" ]; then
        echo "[-] Error: Failed to download firmware archive from $FW_URL"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
    echo "[*] Extracting firmware archive..."
    unzip -q "$ZIP_PATH" -d "$TMP_DIR"
    
    if [ $? -ne 0 ]; then
        echo "[-] Error: Failed to extract $ZIP_PATH. Is it a valid zip file?"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
    # Find the .bin file inside the extracted directory
    BIN_PATH=$(find "$TMP_DIR" -type f -name "*.bin" | head -n 1)
    
    if [ -z "$BIN_PATH" ]; then
        echo "[-] Error: No .bin file found inside the downloaded archive."
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
    echo "[+] Found firmware image: $(basename "$BIN_PATH")"

    echo "[*] Validating firmware image..."
    IMAGE_QUERY=$(mstflint -i "$BIN_PATH" query full 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "[-] Error: $BIN_PATH is not a valid Mellanox firmware image, or cannot be read."
        rm -rf "$TMP_DIR"
        exit 1
    fi

    IMAGE_PSID=$(echo "$IMAGE_QUERY" | grep -E "PSID:" | head -n 1 | awk '{print $2}')
    IMAGE_FW=$(echo "$IMAGE_QUERY" | grep -E "FW Version:" | awk '{print $3}')

    if [ -z "$IMAGE_PSID" ]; then
        echo "[-] Error: Could not extract PSID from the provided image. Aborting."
        rm -rf "$TMP_DIR"
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
    echo "Current FW Version: $TARGET_FW"
    echo "Image FW Version:   $IMAGE_FW"
    echo "============================================================"

    if [[ "$TARGET_FW" == "$IMAGE_FW" ]]; then
        echo ""
        echo "[+] The current firmware version ($TARGET_FW) matches the image."
        echo "    Skipping flash operation."
    else
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
                rm -rf "$TMP_DIR"
                exit 1
            fi
        else
            echo "Flash operation aborted by user."
        fi
    fi
    
    echo "[*] Cleaning up temporary files..."
    rm -rf "$TMP_DIR"
else
    echo "[-] Invalid URL. Exiting."
    exit 1
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