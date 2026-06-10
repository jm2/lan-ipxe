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

# Ensure runtime dependencies for download / extraction / reset are present
for _dep in curl unzip mstfwreset; do
    if ! command -v "$_dep" &> /dev/null; then
        echo "[-] Error: required utility '$_dep' not found."
        case "$_dep" in
            mstfwreset) echo "    'mstfwreset' normally ships with mstflint; reinstall the mstflint package." ;;
            *)          echo "    On Arch Linux, run: pacman -S $_dep" ;;
        esac
        exit 1
    fi
done

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

# Map a hardware family name to a coarse silicon generation key. Variants that
# share a firmware branch (e.g. CX5 / CX5 Ex, CX3 / CX3 Pro) collapse together.
get_gen_from_family() {
    case "$1" in
        "ConnectX-3"|"ConnectX-3 Pro") echo "CX3" ;;
        "ConnectX-4")                  echo "CX4" ;;
        "ConnectX-4 Lx")               echo "CX4Lx" ;;
        "ConnectX-5"|"ConnectX-5 Ex")  echo "CX5" ;;
        "ConnectX-6")                  echo "CX6" ;;
        "ConnectX-6 Dx")               echo "CX6Dx" ;;
        "ConnectX-6 Lx")               echo "CX6Lx" ;;
        "ConnectX-7")                  echo "CX7" ;;
        *)                             echo "" ;;
    esac
}

# Map a firmware MAJOR version to the same coarse silicon generation key.
# (ConnectX-3=2.x, CX4=12.x, CX4 Lx=14.x, CX5=16.x, CX6=20.x, CX6 Dx=22.x,
#  CX6 Lx=26.x, CX7=28.x)
get_gen_from_fw_major() {
    case "$1" in
        2)  echo "CX3" ;;
        12) echo "CX4" ;;
        14) echo "CX4Lx" ;;
        16) echo "CX5" ;;
        20) echo "CX6" ;;
        22) echo "CX6Dx" ;;
        26) echo "CX6Lx" ;;
        28) echo "CX7" ;;
        *)  echo "" ;;
    esac
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

    # --- Safety gate: never flash a device whose initial query failed ---
    # A failed 'mstflint query' leaves TARGET_PSID empty. An empty PSID can never
    # equal the image PSID, so the logic below would auto-classify the burn as a
    # cross-flash and blindly apply -allow_psid_change/-allow_rom_change.
    if [[ -z "$TARGET_PSID" ]]; then
        echo "[-] Device $TARGET_DEV is not queryable (empty PSID) -- refusing to flash."
        echo "    A blank PSID means 'mstflint query' failed; this is normal for a card stuck"
        echo "    in livefish/recovery mode. Auto-flashing here would force -allow_psid_change"
        echo "    and -allow_rom_change against an unknown device, which can BRICK the card."
        echo "    If this card is genuinely in recovery mode, flash it directly with mstflint"
        echo "    recovery mode AFTER you have confirmed the exact correct image, e.g.:"
        echo "        mstflint -d $TARGET_DEV -i <image>.bin -allow_psid_change burn"
        exit 1
    fi

    # Create a temporary working directory
    TMP_DIR=$(mktemp -d -t mlnx_fw_XXXXXX)
    echo "[*] Created temporary working directory: $TMP_DIR"

    ZIP_PATH="$TMP_DIR/firmware.zip"
    echo "[*] Downloading firmware archive from NVIDIA..."

    # Download the file: -f fails on HTTP errors (so a 404 HTML page is NOT saved as
    # firmware.zip), -L follows redirects, -# shows a progress bar.
    curl -fL -# -o "$ZIP_PATH" "$FW_URL"
    CURL_RC=$?
    if [ "$CURL_RC" -ne 0 ]; then
        echo "[-] Error: Failed to download firmware archive from $FW_URL (curl exit $CURL_RC)."
        echo "    Make sure this is a DIRECT link to the .zip; error pages/redirects to HTML are rejected."
        rm -rf "$TMP_DIR"
        exit 1
    fi

    if [ ! -s "$ZIP_PATH" ]; then
        echo "[-] Error: Downloaded archive is empty or missing."
        rm -rf "$TMP_DIR"
        exit 1
    fi

    # Verify archive integrity first so a truncated / partial download is caught
    # cleanly instead of producing a confusing half-extracted tree.
    if ! unzip -tq "$ZIP_PATH" &> /dev/null; then
        echo "[-] Error: $ZIP_PATH is not a valid/complete zip (download may be truncated or an HTML error page)."
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "[*] Extracting firmware archive..."
    if ! unzip -q "$ZIP_PATH" -d "$TMP_DIR"; then
        echo "[-] Error: Failed to extract $ZIP_PATH. Is it a valid zip file?"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    # Find the .bin file(s) inside the extracted directory. If more than one is
    # present, make the operator choose rather than silently guessing.
    mapfile -t BIN_FILES < <(find "$TMP_DIR" -type f -name "*.bin" | sort)

    if [ "${#BIN_FILES[@]}" -eq 0 ]; then
        echo "[-] Error: No .bin file found inside the downloaded archive."
        rm -rf "$TMP_DIR"
        exit 1
    elif [ "${#BIN_FILES[@]}" -eq 1 ]; then
        BIN_PATH="${BIN_FILES[0]}"
    else
        echo "[!] Multiple .bin files were found in the archive:"
        for idx in "${!BIN_FILES[@]}"; do
            echo "    [$((idx + 1))] ${BIN_FILES[$idx]}"
        done
        read -p "Select which .bin to flash (1-${#BIN_FILES[@]}): " BIN_CHOICE
        if ! [[ "$BIN_CHOICE" =~ ^[0-9]+$ ]] || [ "$BIN_CHOICE" -lt 1 ] || [ "$BIN_CHOICE" -gt "${#BIN_FILES[@]}" ]; then
            echo "[-] Invalid selection."
            rm -rf "$TMP_DIR"
            exit 1
        fi
        BIN_PATH="${BIN_FILES[$((BIN_CHOICE - 1))]}"
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
    IMAGE_PN=$(echo "$IMAGE_QUERY" | grep -iE "Part Number:" | head -n 1 | sed 's/^[ \t]*Part Number:[ \t]*//')

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
    echo "Current Part No:    $TARGET_PN"
    echo "Image Part No:      ${IMAGE_PN:-<not present in image>}"
    echo "Current PSID:       $TARGET_PSID"
    echo "Image PSID:         $IMAGE_PSID"
    echo "Current FW Version: $TARGET_FW"
    echo "Image FW Version:   $IMAGE_FW"
    echo "============================================================"

    # --- Image vs device family cross-check (defense-in-depth) ---
    # mstflint's own chip-type check already blocks cross-GENERATION images, but
    # -allow_psid_change disables the within-generation wrong-board guard, so we
    # independently derive the image's family from its FW major version and refuse
    # any burn where the families disagree.
    IMAGE_FW_MAJOR="${IMAGE_FW%%.*}"
    IMAGE_GEN=$(get_gen_from_fw_major "$IMAGE_FW_MAJOR")
    TARGET_GEN=$(get_gen_from_family "$TARGET_FAMILY")

    if [[ -n "$IMAGE_GEN" && -n "$TARGET_GEN" && "$IMAGE_GEN" != "$TARGET_GEN" ]]; then
        echo ""
        echo "[-] FATAL: Firmware family mismatch -- refusing to flash."
        echo "    Device family: $TARGET_FAMILY (generation $TARGET_GEN)"
        echo "    Image FW $IMAGE_FW implies generation: $IMAGE_GEN"
        echo "    Burning a wrong-family image (especially with -allow_psid_change) WILL brick the card."
        rm -rf "$TMP_DIR"
        exit 1
    elif [[ -z "$IMAGE_GEN" || -z "$TARGET_GEN" ]]; then
        echo "[!] Warning: could not positively cross-check image family"
        echo "    (image generation='${IMAGE_GEN:-unknown}', device generation='${TARGET_GEN:-unknown}')."
        echo "    Verify manually that this image matches the hardware before continuing."
    fi

    if [[ "$TARGET_FW" == "$IMAGE_FW" && "$TARGET_PSID" == "$IMAGE_PSID" ]]; then
        echo ""
        echo "[+] The current firmware version ($TARGET_FW) matches the image."
        echo "    Skipping flash operation."
    else
        # Determine if we are cross-flashing or doing a standard update.
        # A cross-flash == the image PSID differs from the device PSID (note the
        # empty-PSID case is already rejected by the safety gate above).
        FLASH_CMD="mstflint -d \"$TARGET_DEV\" -i \"$BIN_PATH\""
        if [[ "$TARGET_PSID" == "$IMAGE_PSID" ]]; then
            IS_CROSSFLASH=0
        else
            IS_CROSSFLASH=1
        fi

        if [[ "$IS_CROSSFLASH" -eq 1 ]]; then
            echo "[!] CROSS-FLASH DETECTED (PSID mismatch)."
            echo "    The script forces -allow_psid_change and -allow_rom_change."
            echo "    WARNING: If this image is not meant for a $TARGET_FAMILY architecture, "
            echo "    it WILL brick the network card!"
            FLASH_CMD="$FLASH_CMD -allow_psid_change -allow_rom_change burn"
        else
            echo "[+] Standard Update Detected (PSIDs match)."
            FLASH_CMD="$FLASH_CMD burn"
        fi

        echo ""
        read -p "Are you ABSOLUTELY sure you want to proceed? Type 'YES' in all caps to burn: " CONFIRM

        if [[ "$CONFIRM" == "YES" ]]; then
            echo "[*] Initiating firmware burn..."
            
            # Eval is used here to parse the constructed string properly
            eval $FLASH_CMD
            
            if [ $? -eq 0 ]; then
                echo "[+] Flash successful!"

                # ConnectX-3 / CX3 Pro (4th-gen silicon) does NOT support mstfwreset.
                if [[ "$TARGET_FAMILY" == "ConnectX-3" || "$TARGET_FAMILY" == "ConnectX-3 Pro" ]]; then
                    echo "[!] $TARGET_FAMILY does not support mstfwreset."
                    echo "    Reboot the system (or unload/reload the mlx4_core driver) to activate the new firmware."
                else
                    # Further automation: Prompt to reset device immediately
                    read -p "Would you like to reset the NIC firmware now (avoids system reboot)? (y/n): " DO_RESET
                    if [[ "$DO_RESET" == "y" || "$DO_RESET" == "Y" ]]; then
                        echo "[*] Resetting firmware on $TARGET_DEV..."
                        if mstfwreset -d "$TARGET_DEV" -y reset; then
                            echo "[+] Firmware reset complete."
                        else
                            echo "[-] Firmware reset FAILED. The new firmware is flashed but NOT yet active."
                            echo "    A full system reboot (or driver unload/reload) is REQUIRED to load it."
                        fi
                    fi
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
    if [[ "$TARGET_FAMILY" == "ConnectX-3" || "$TARGET_FAMILY" == "ConnectX-3 Pro" ]]; then
        # ConnectX-3 / CX3 Pro do NOT have the 5th-gen+ UEFI TLVs
        # (EXP_ROM_UEFI_x86_ENABLE / EXP_ROM_UEFI_ARM_ENABLE / UEFI_HII_EN /
        # EXP_ROM_PXE_ENABLE). Applying that block as a single atomic 'set' fails
        # outright, so we apply only CX3-relevant keys, each in its OWN call, and
        # tolerate per-key failure so one unsupported key does not void the rest.
        echo "[*] $TARGET_FAMILY uses legacy firmware-config TLVs; applying CX3 boot keys one at a time..."
        echo "    NOTE: the CX3 key/value names below are best-effort; unsupported keys are skipped with a warning."
        CX3_KEYS=(
            "LEGACY_BOOT_PROTOCOL_P1=1"
            "LEGACY_BOOT_PROTOCOL_P2=1"
            "BOOT_OPTION_ROM_EN_P1=1"
            "BOOT_OPTION_ROM_EN_P2=1"
        )
        CX3_APPLIED=0
        for kv in "${CX3_KEYS[@]}"; do
            echo "    -> mstconfig set $kv"
            if mstconfig -y -d "$TARGET_DEV" set "$kv" &> /dev/null; then
                echo "       [+] applied"
                CX3_APPLIED=1
            else
                echo "       [!] skipped (key unsupported on this firmware)"
            fi
        done
        if [ "$CX3_APPLIED" -eq 1 ]; then
            echo "[+] ConnectX-3 boot configuration applied (see per-key results above)."
        else
            echo "[-] No ConnectX-3 boot keys were accepted."
            echo "    Inspect the supported keys with: mstconfig -d $TARGET_DEV query"
        fi
    else
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
fi

echo ""
if [[ "$TARGET_FAMILY" == "ConnectX-3" || "$TARGET_FAMILY" == "ConnectX-3 Pro" ]]; then
    echo "[!] A complete system reboot (or unload/reload of the mlx4_core driver) is required for changes to take effect."
else
    echo "[!] A complete system reboot (or 'mstfwreset -d $TARGET_DEV -y reset') is required for changes to take effect."
fi