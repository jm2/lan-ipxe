#!/bin/bash
set -e
# Note: pipefail intentionally not enabled. Several scrape helpers use
# `curl | grep | head` and rely on grep's non-zero exit (no match) being
# absorbed by the trailing pipeline stage. Empty results are then handled
# explicitly by the SKIP_* flags below.

# ==========================================
# Configuration Variables
# ==========================================
PXE_SERVER="192.168.1.11:81"
PXE_HTTP_DIR="/srv/http/pxe"
TFTP_DIR="/srv/tftp"

ENABLE_LOCAL_ARCH="false"        # Set to "true" to copy local Arch Kernel/Initrd
ENABLE_TFTP_BOOTSTRAP="false"    # Set to "true" to download iPXE binaries to TFTP_DIR
ENABLE_CUSTOM_ARCHISO="false"    # Set to "true" to enable Custom Archiso Menu
ENABLE_WIN11_PXE="false"         # Set to "true" to enable Windows 11 iSCSI Boot

PURDUE_MIRROR="https://plug-mirror.rcac.purdue.edu"
FEDORA_MIRROR_BASE="https://plug-mirror.rcac.purdue.edu/fedora/fedora/linux/releases"
NETBOOT_XYZ_URL="https://boot.netboot.xyz"

# ==========================================
# Setup & Permissions Check
# ==========================================

# Fallback for testing if directories aren't writable
if [ ! -w "$PXE_HTTP_DIR" ]; then
    echo "WARNING: $PXE_HTTP_DIR is not writable. Using ./pxe_test/http instead."
    PXE_HTTP_DIR="./pxe_test/http"
    mkdir -p "$PXE_HTTP_DIR"
fi

if [ ! -w "$TFTP_DIR" ]; then
    echo "WARNING: $TFTP_DIR is not writable. Using ./pxe_test/tftp instead."
    TFTP_DIR="./pxe_test/tftp"
    mkdir -p "$TFTP_DIR"
fi

# Ensure HTTP dir exists (for bg.png)
mkdir -p "$PXE_HTTP_DIR"

IPXE_FILE="$TFTP_DIR/default.ipxe"

echo "========================================"
echo " PXE Update & Generator Script"
echo "========================================"
echo "PXE Server: $PXE_SERVER"
echo "HTTP Dir:   $PXE_HTTP_DIR"
echo "TFTP Dir:   $TFTP_DIR"
echo "Output:     $IPXE_FILE"
echo "========================================"

# ==========================================
# Helper Functions
# ==========================================

check_url_exists() {
    local url=$1
    local code
    code=$(curl -sLI -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

# Resolve the latest tag in a netboot.xyz repo whose name starts with $prefix-.
# Used to find the current kernel/initrd assets for live boot.
# Note: as of 2026-04, kernel/initrd for Debian live moved out of debian-squash
# (which now ships only filesystem.squashfs) and into debian-core-${MAJOR}.
# Ubuntu still ships vmlinuz/initrd inside ubuntu-squash.
get_netbootxyz_tag() {
    local repo=$1     # ubuntu-squash, debian-core-13, etc.
    local prefix=$2   # e.g. 13.4.0 or 26.04
    curl -sL --max-time 15 "https://api.github.com/repos/netbootxyz/${repo}/releases?per_page=100" 2>/dev/null | \
        grep -oP '"tag_name":\s*"\K[^"]+' | \
        grep "^${prefix}-" | head -n 1
}

# --- Debian ---
get_debian_version() {
    local arch=$1
    # Debian arch in URL: amd64, arm64
    curl -sL "${PURDUE_MIRROR}/debian-cd/current-live/${arch}/iso-hybrid/" | \
        grep -oP 'debian-live-\K[\d\.]+(?=-'"${arch}"'-gnome\.iso)' | head -n 1
}

# --- Fedora ---
get_fedora_version() {
    local arch=$1 # x86_64, aarch64
    # Scrape RIT mirror
    
    local versions=$(curl -sL "${FEDORA_MIRROR_BASE}/" | grep -oP 'href="\K\d+(?=/")' | sort -rV)
    for ver in $versions; do
        # Check if directories exist
        if check_url_exists "${FEDORA_MIRROR_BASE}/${ver}/Workstation/${arch}/iso/"; then
             echo "$ver"
             return 0
        fi
    done
    echo ""
}
# Returns "<flavor_dir>|<iso_name>" so callers can emit the right directory in iPXE.
# Fedora 44 promoted KDE Plasma from a Spin to a top-level Edition: ISO moved from
# Spins/ to KDE/ and the filename changed from Fedora-KDE-Live-* to
# Fedora-KDE-Desktop-Live-*. We try the new location first and fall back to Spins.
get_fedora_iso() {
    local ver=$1
    local variant=$2 # gnome, kde, xfce
    local arch=$3    # x86_64, aarch64
    local url_base="${FEDORA_MIRROR_BASE}/${ver}"
    local iso=""

    case "$variant" in
        gnome)
            iso=$(curl -sL "${url_base}/Workstation/${arch}/iso/" 2>/dev/null | \
                grep -oP "Fedora-Workstation-Live-[^\"]*${arch}\.iso" | head -n 1)
            [ -n "$iso" ] && echo "Workstation|${iso}"
            ;;
        kde)
            iso=$(curl -sL "${url_base}/KDE/${arch}/iso/" 2>/dev/null | \
                grep -oP "Fedora-KDE-Desktop-Live-[^\"]*${arch}\.iso" | head -n 1)
            if [ -n "$iso" ]; then
                echo "KDE|${iso}"
            else
                iso=$(curl -sL "${url_base}/Spins/${arch}/iso/" 2>/dev/null | \
                    grep -oP "Fedora-KDE-Live-[^\"]*${arch}\.iso" | head -n 1)
                [ -n "$iso" ] && echo "Spins|${iso}"
            fi
            ;;
        xfce)
            iso=$(curl -sL "${url_base}/Spins/${arch}/iso/" 2>/dev/null | \
                grep -oP "Fedora-Xfce-Live-[^\"]*${arch}\.iso" | head -n 1)
            [ -n "$iso" ] && echo "Spins|${iso}"
            ;;
    esac
}

# --- Rocky ---
# Some Rocky mirrors use 'live' (lowercase), others 'Live'. Detect once and reuse.
get_rocky_live_dir() {
    local ver=$1
    local arch=$2
    for dir in "live" "Live"; do
        if check_url_exists "${PURDUE_MIRROR}/rocky/${ver}/${dir}/${arch}/"; then
            echo "$dir"
            return 0
        fi
    done
    echo ""
}
get_rocky_version() {
    local arch=$1 # x86_64, aarch64
    local versions=$(curl -sL "${PURDUE_MIRROR}/rocky/" | grep -oP 'href="\K[\d\.]+(?=/")' | sort -rV)
    for ver in $versions; do
        if [ -n "$(get_rocky_live_dir "$ver" "$arch")" ]; then
            echo "$ver"
            return 0
        fi
    done
    echo ""
}
get_rocky_iso() {
    local ver=$1
    local variant=$2 # gnome (Workstation), kde, xfce
    local arch=$3    # x86_64, aarch64
    local live_dir=$4

    local iso_pattern=""
    case "$variant" in
        gnome) iso_pattern="href=\"\KRocky-[\d\.\-]+-Workstation(-Live)?-${arch}[^\"]*\.iso" ;;
        kde)   iso_pattern="href=\"\KRocky-[\d\.\-]+-KDE(-Live)?-${arch}[^\"]*\.iso" ;;
        xfce)  iso_pattern="href=\"\KRocky-[\d\.\-]+-XFCE(-Live)?-${arch}[^\"]*\.iso" ;;
    esac

    curl -sL "${PURDUE_MIRROR}/rocky/${ver}/${live_dir}/${arch}/" | grep -oP "$iso_pattern" | head -n 1
}

# --- Ubuntu LTS (x86_64 only — desktop ISO ships GNOME) ---
# LTS = even-numbered year, .04 release. We pick the highest YY.04 with an even YY.
get_ubuntu_lts_version() {
    local versions
    versions=$(curl -sL "${PURDUE_MIRROR}/ubuntu-releases/" | grep -oP 'href="\K\d+\.\d+(?=/")' | sort -rV | uniq)
    for ver in $versions; do
        local year="${ver%%.*}"
        local point="${ver##*.}"
        if (( year % 2 == 0 )) && [ "$point" = "04" ]; then
            if check_url_exists "${PURDUE_MIRROR}/ubuntu-releases/${ver}/"; then
                echo "$ver"
                return 0
            fi
        fi
    done
    echo ""
}
get_ubuntu_iso() {
    local ver=$1
    # Matches both ubuntu-26.04-desktop-amd64.iso and ubuntu-24.04.3-desktop-amd64.iso
    curl -sL "${PURDUE_MIRROR}/ubuntu-releases/${ver}/" | \
        grep -oP "ubuntu-${ver}(\.\d+)?-desktop-amd64\.iso" | head -n 1
}

# ==========================================
# 1. TFTP Bootstrapping
# ==========================================
if [ "$ENABLE_TFTP_BOOTSTRAP" = "true" ]; then
    echo "Downloading iPXE binaries to $TFTP_DIR..."
    # x86_64
    echo "  [x86_64] ipxe.efi (Using snponly.efi for better UEFI keyboard compatibility)"
    # We save snponly.efi as ipxe.efi so we don't have to change DHCP server config.
    curl -sL -o "$TFTP_DIR/ipxe.efi" "http://boot.ipxe.org/x86_64-efi/snponly.efi"
    echo "  [Legacy] undionly.kpxe"
    curl -sL -o "$TFTP_DIR/undionly.kpxe" "https://boot.ipxe.org/undionly.kpxe"
    # AArch64 (ARM64) - using ipxe.org stock
    # Using snponly.efi for ARM64 as well to avoid similar driver conflicts
    if curl -sI "http://boot.ipxe.org/arm64-efi/snponly.efi" | head -n 1 | grep -q "200"; then
        echo "  [ARM64]  ipxe-arm64.efi (snponly.efi)"
        curl -sL -o "$TFTP_DIR/ipxe-arm64.efi" "http://boot.ipxe.org/arm64-efi/snponly.efi"
    else
        echo "  [WARNING] Could not find stock arm64 snponly.efi. Skipping."
    fi
else
    echo "Skipping TFTP bootstrap download (Not enabled)."
fi

# Check for Background Image (Required for Console)
if [ ! -f "$PXE_HTTP_DIR/bg.png" ]; then
    echo "Downloading background image to $PXE_HTTP_DIR/bg.png..."
    curl -sL -o "$PXE_HTTP_DIR/bg.png" "http://boot.ipxe.org/ipxe.png"
    
    # Verify it is actually a PNG (magic bytes)
    if ! file "$PXE_HTTP_DIR/bg.png" | grep -q "PNG image data"; then
        echo "  [WARNING] Downloaded bg.png is not a valid PNG. Deleting..."
        rm -f "$PXE_HTTP_DIR/bg.png"
    fi
fi

# ==========================================
# 2. Local Arch Kernel (Optional)
# ==========================================
if [ "$ENABLE_LOCAL_ARCH" = "true" ]; then
    echo "Updating Local Arch Linux files from /srv/arch..."
    
    # Mount if not already mounted
    if ! mountpoint -q /srv/arch; then
        mount /srv/arch || { echo "  [ERROR] Failed to mount /srv/arch"; exit 1; }
        MOUNTED_ARCH="true"
    else
        MOUNTED_ARCH="false"
    fi

    # Check for vmlinuz in /srv/arch/boot or /srv/arch depending on partition layout
    if [ -f /srv/arch/boot/vmlinuz-linux ]; then
        cp -f /srv/arch/boot/vmlinuz-linux "$PXE_HTTP_DIR/vmlinuz-linux"
        cp -f /srv/arch/boot/initramfs-linux.img "$PXE_HTTP_DIR/initramfs-linux.img"
        chmod 644 "$PXE_HTTP_DIR/vmlinuz-linux" "$PXE_HTTP_DIR/initramfs-linux.img"
        echo "  Copied from /srv/arch/boot."
    else
        echo "  [WARNING] vmlinuz-linux not found in /srv/arch/boot."
    fi

    # Unmount if we mounted it
    if [ "$MOUNTED_ARCH" = "true" ]; then
        umount /srv/arch || echo "  [WARNING] Failed to unmount /srv/arch"
    fi
else
    echo "Skipping Local Arch Copy (Not enabled)."
fi

# ==========================================
# 3. Clonezilla (Netboot.xyz)
# ==========================================
echo "Processing Clonezilla..."
echo "  Using Netboot.xyz assets (3.3.0-33-1a41a72c)"

# ==========================================
# 4. Version Scrape (x86_64)
# ==========================================
echo "Detecting x86_64 Versions..."

# Track which sections to skip rather than emit broken menu entries.
SKIP_DEBIAN_X86="false"
SKIP_FEDORA_X86="false"
SKIP_ROCKY_X86="false"
SKIP_UBUNTU_X86="false"

DEBIAN_VER_X86=$(get_debian_version "amd64")
if [ -n "$DEBIAN_VER_X86" ]; then
    DEBIAN_CORE_REPO_X86="debian-core-${DEBIAN_VER_X86%%.*}"
    DEBIAN_TAG_X86=$(get_netbootxyz_tag "$DEBIAN_CORE_REPO_X86" "$DEBIAN_VER_X86")
    if [ -z "$DEBIAN_TAG_X86" ]; then
        echo "  [WARNING] No netboot.xyz ${DEBIAN_CORE_REPO_X86} tag found for ${DEBIAN_VER_X86}; skipping Debian x86_64."
        SKIP_DEBIAN_X86="true"
    fi
else
    echo "  [WARNING] Debian version scrape failed; skipping Debian x86_64."
    SKIP_DEBIAN_X86="true"
fi
echo "  Debian (x86_64):  ${DEBIAN_VER_X86:-?} (repo: ${DEBIAN_CORE_REPO_X86:-?}, tag: ${DEBIAN_TAG_X86:-none})"

FEDORA_VER_X86=$(get_fedora_version "x86_64")
if [ -n "$FEDORA_VER_X86" ]; then
    _g=$(get_fedora_iso "$FEDORA_VER_X86" "gnome" "x86_64")
    _k=$(get_fedora_iso "$FEDORA_VER_X86" "kde"   "x86_64")
    _x=$(get_fedora_iso "$FEDORA_VER_X86" "xfce"  "x86_64")
    FEDORA_DIR_GNOME_X86="${_g%%|*}"; FEDORA_ISO_GNOME_X86="${_g#*|}"; [ "$_g" = "" ] && FEDORA_ISO_GNOME_X86=""
    FEDORA_DIR_KDE_X86="${_k%%|*}";   FEDORA_ISO_KDE_X86="${_k#*|}";   [ "$_k" = "" ] && FEDORA_ISO_KDE_X86=""
    FEDORA_DIR_XFCE_X86="${_x%%|*}";  FEDORA_ISO_XFCE_X86="${_x#*|}";  [ "$_x" = "" ] && FEDORA_ISO_XFCE_X86=""
    if [ -z "$FEDORA_ISO_GNOME_X86" ] && [ -z "$FEDORA_ISO_KDE_X86" ] && [ -z "$FEDORA_ISO_XFCE_X86" ]; then
        echo "  [WARNING] Fedora ${FEDORA_VER_X86} found but no ISOs matched; skipping Fedora x86_64."
        SKIP_FEDORA_X86="true"
    fi
else
    echo "  [WARNING] Fedora version scrape failed; skipping Fedora x86_64."
    SKIP_FEDORA_X86="true"
fi
echo "  Fedora (x86_64):  ${FEDORA_VER_X86:-?} (G: ${FEDORA_ISO_GNOME_X86:-none} | K: ${FEDORA_ISO_KDE_X86:-none}@${FEDORA_DIR_KDE_X86:-?})"

ROCKY_VER_X86=$(get_rocky_version "x86_64")
if [ -n "$ROCKY_VER_X86" ]; then
    ROCKY_LIVE_DIR_X86=$(get_rocky_live_dir "$ROCKY_VER_X86" "x86_64")
    ROCKY_ISO_GNOME_X86=$(get_rocky_iso "$ROCKY_VER_X86" "gnome" "x86_64" "$ROCKY_LIVE_DIR_X86")
    ROCKY_ISO_KDE_X86=$(get_rocky_iso "$ROCKY_VER_X86" "kde" "x86_64" "$ROCKY_LIVE_DIR_X86")
    ROCKY_ISO_XFCE_X86=$(get_rocky_iso "$ROCKY_VER_X86" "xfce" "x86_64" "$ROCKY_LIVE_DIR_X86")
    if [ -z "$ROCKY_ISO_GNOME_X86" ] && [ -z "$ROCKY_ISO_KDE_X86" ] && [ -z "$ROCKY_ISO_XFCE_X86" ]; then
        echo "  [WARNING] Rocky ${ROCKY_VER_X86} found but no ISOs matched; skipping Rocky x86_64."
        SKIP_ROCKY_X86="true"
    fi
else
    echo "  [WARNING] Rocky version scrape failed; skipping Rocky x86_64."
    SKIP_ROCKY_X86="true"
fi
echo "  Rocky (x86_64):   ${ROCKY_VER_X86:-?} (dir: ${ROCKY_LIVE_DIR_X86:-?}, G: ${ROCKY_ISO_GNOME_X86:-none})"

UBUNTU_VER_X86=$(get_ubuntu_lts_version)
if [ -n "$UBUNTU_VER_X86" ]; then
    UBUNTU_ISO_X86=$(get_ubuntu_iso "$UBUNTU_VER_X86")
    UBUNTU_TAG_X86=$(get_netbootxyz_tag "ubuntu-squash" "$UBUNTU_VER_X86")
    if [ -z "$UBUNTU_ISO_X86" ] || [ -z "$UBUNTU_TAG_X86" ]; then
        echo "  [WARNING] Ubuntu ${UBUNTU_VER_X86} missing ISO (${UBUNTU_ISO_X86:-none}) or netboot.xyz tag (${UBUNTU_TAG_X86:-none}); skipping."
        SKIP_UBUNTU_X86="true"
    fi
else
    echo "  [WARNING] No Ubuntu LTS found on mirror; skipping Ubuntu."
    SKIP_UBUNTU_X86="true"
fi
echo "  Ubuntu LTS:       ${UBUNTU_VER_X86:-?} (tag: ${UBUNTU_TAG_X86:-none}, ISO: ${UBUNTU_ISO_X86:-none})"

# ==========================================
# 5. Version Scrape (ARM64)
# ==========================================
echo "Detecting ARM64 Versions..."

DEBIAN_VER_ARM=$(get_debian_version "arm64")
if [ -n "$DEBIAN_VER_ARM" ]; then
    DEBIAN_CORE_REPO_ARM="debian-core-${DEBIAN_VER_ARM%%.*}"
    DEBIAN_TAG_ARM=$(get_netbootxyz_tag "$DEBIAN_CORE_REPO_ARM" "$DEBIAN_VER_ARM")
    if [ -z "$DEBIAN_TAG_ARM" ]; then
        echo "  [WARNING] No netboot.xyz ${DEBIAN_CORE_REPO_ARM} tag for ${DEBIAN_VER_ARM} ARM64; skipping."
        DEBIAN_VER_ARM=""
    fi
fi
echo "  Debian (ARM64):  ${DEBIAN_VER_ARM:-Skipped}"

FEDORA_VER_ARM=$(get_fedora_version "aarch64")
if [ -n "$FEDORA_VER_ARM" ]; then
    _g=$(get_fedora_iso "$FEDORA_VER_ARM" "gnome" "aarch64")
    _k=$(get_fedora_iso "$FEDORA_VER_ARM" "kde"   "aarch64")
    _x=$(get_fedora_iso "$FEDORA_VER_ARM" "xfce"  "aarch64")
    FEDORA_DIR_GNOME_ARM="${_g%%|*}"; FEDORA_ISO_GNOME_ARM="${_g#*|}"; [ "$_g" = "" ] && FEDORA_ISO_GNOME_ARM=""
    FEDORA_DIR_KDE_ARM="${_k%%|*}";   FEDORA_ISO_KDE_ARM="${_k#*|}";   [ "$_k" = "" ] && FEDORA_ISO_KDE_ARM=""
    FEDORA_DIR_XFCE_ARM="${_x%%|*}";  FEDORA_ISO_XFCE_ARM="${_x#*|}";  [ "$_x" = "" ] && FEDORA_ISO_XFCE_ARM=""
    if [ -z "$FEDORA_ISO_GNOME_ARM" ] && [ -z "$FEDORA_ISO_KDE_ARM" ] && [ -z "$FEDORA_ISO_XFCE_ARM" ]; then
         FEDORA_VER_ARM=""
    fi
fi
echo "  Fedora (ARM64):  ${FEDORA_VER_ARM:-Skipped}"

ROCKY_VER_ARM=$(get_rocky_version "aarch64")
if [ -n "$ROCKY_VER_ARM" ]; then
    ROCKY_LIVE_DIR_ARM=$(get_rocky_live_dir "$ROCKY_VER_ARM" "aarch64")
    ROCKY_ISO_GNOME_ARM=$(get_rocky_iso "$ROCKY_VER_ARM" "gnome" "aarch64" "$ROCKY_LIVE_DIR_ARM")
    ROCKY_ISO_KDE_ARM=$(get_rocky_iso "$ROCKY_VER_ARM" "kde" "aarch64" "$ROCKY_LIVE_DIR_ARM")
    ROCKY_ISO_XFCE_ARM=$(get_rocky_iso "$ROCKY_VER_ARM" "xfce" "aarch64" "$ROCKY_LIVE_DIR_ARM")
    if [ -z "$ROCKY_ISO_GNOME_ARM" ] && [ -z "$ROCKY_ISO_KDE_ARM" ] && [ -z "$ROCKY_ISO_XFCE_ARM" ]; then
         ROCKY_VER_ARM=""
    fi
fi
echo "  Rocky (ARM64):   ${ROCKY_VER_ARM:-Skipped} (dir: ${ROCKY_LIVE_DIR_ARM:-?})"

# ==========================================
# 6. Generate iPXE
# ==========================================
echo "Generating $IPXE_FILE..."

cat > "$IPXE_FILE" <<EOF
#!ipxe

# Generated by update-pxe-images.sh
# Date: $(date)
# Server: ${PXE_SERVER}

# --- Console Config ---
# Force resolution and background to ensure GOP/keyboard works in UEFI
console --picture http://${PXE_SERVER}/pxe/bg.png --x 1920 --y 1080 ||

# --- Architecture Check ---
iseq \${buildarch} arm64 && goto arm64_menu || goto x86_64_menu

# ============================================================================
#                               ARM64 MENU
# ============================================================================
:arm64_menu
menu iPXE Boot Menu (ARM64)
item netbootxyz           Netboot.xyz (ARM64)
item shell                iPXE Shell
item --gap --             ------------------------- ARM64 Live -------------------------
EOF

# Add Debian ARM if found
if [ -n "$DEBIAN_VER_ARM" ]; then
    cat >> "$IPXE_FILE" <<EOF
item debian-gnome-arm     Debian ${DEBIAN_VER_ARM} (GNOME)
EOF
fi

# Add Fedora ARM if found
if [ -n "$FEDORA_VER_ARM" ]; then
    [ -n "$FEDORA_ISO_GNOME_ARM" ] && echo "item fedora-gnome-arm      Fedora ${FEDORA_VER_ARM} (GNOME)" >> "$IPXE_FILE"
    [ -n "$FEDORA_ISO_KDE_ARM" ]   && echo "item fedora-kde-arm        Fedora ${FEDORA_VER_ARM} (KDE)" >> "$IPXE_FILE"
    [ -n "$FEDORA_ISO_XFCE_ARM" ]  && echo "item fedora-xfce-arm       Fedora ${FEDORA_VER_ARM} (XFCE)" >> "$IPXE_FILE"
fi

# Add Rocky ARM if found
if [ -n "$ROCKY_VER_ARM" ]; then
    [ -n "$ROCKY_ISO_GNOME_ARM" ] && echo "item rocky-gnome-arm       Rocky ${ROCKY_VER_ARM} (GNOME)" >> "$IPXE_FILE"
    [ -n "$ROCKY_ISO_KDE_ARM" ]   && echo "item rocky-kde-arm         Rocky ${ROCKY_VER_ARM} (KDE)" >> "$IPXE_FILE"
    [ -n "$ROCKY_ISO_XFCE_ARM" ]  && echo "item rocky-xfce-arm        Rocky ${ROCKY_VER_ARM} (XFCE)" >> "$IPXE_FILE"
fi

cat >> "$IPXE_FILE" <<EOF

choose --default netbootxyz --timeout 10000 bootoption && goto \${bootoption} || goto :arm64_menu

# ============================================================================
#                               x86_64 MENU
# ============================================================================
:x86_64_menu
menu iPXE Boot Menu (x86_64)
item --gap --             ------------------------- Local Tools ------------------------
item local                Local Disk
item clonezilla           Clonezilla Live (Netboot)
EOF

if [ "$ENABLE_LOCAL_ARCH" = "true" ]; then
    echo "item lan-image            Arch Linux LAN Gaming Image (Local)" >> "$IPXE_FILE"
fi

if [ "$ENABLE_WIN11_PXE" = "true" ]; then
    echo "item win11-pxe            Windows 11 (iSCSI Boot)" >> "$IPXE_FILE"
fi

if [ "$SKIP_DEBIAN_X86" = "false" ]; then
    cat >> "$IPXE_FILE" <<EOF
item --gap --             ------------------------- Debian Live ------------------------
item debian-gnome         Debian ${DEBIAN_VER_X86} (GNOME)
item debian-kde           Debian ${DEBIAN_VER_X86} (KDE)
item debian-xfce          Debian ${DEBIAN_VER_X86} (XFCE)
EOF
fi

if [ "$SKIP_UBUNTU_X86" = "false" ]; then
    cat >> "$IPXE_FILE" <<EOF
item --gap --             ------------------------- Ubuntu LTS -------------------------
item ubuntu-gnome         Ubuntu ${UBUNTU_VER_X86} LTS (GNOME)
EOF
fi

if [ "$SKIP_FEDORA_X86" = "false" ]; then
    cat >> "$IPXE_FILE" <<EOF
item --gap --             ------------------------- Fedora Live ------------------------
EOF
    [ -n "$FEDORA_ISO_GNOME_X86" ] && echo "item fedora-gnome         Fedora ${FEDORA_VER_X86} (GNOME)" >> "$IPXE_FILE"
    [ -n "$FEDORA_ISO_KDE_X86" ]   && echo "item fedora-kde           Fedora ${FEDORA_VER_X86} (KDE)"   >> "$IPXE_FILE"
    [ -n "$FEDORA_ISO_XFCE_X86" ]  && echo "item fedora-xfce          Fedora ${FEDORA_VER_X86} (XFCE)"  >> "$IPXE_FILE"
fi

if [ "$SKIP_ROCKY_X86" = "false" ]; then
    cat >> "$IPXE_FILE" <<EOF
item --gap --             ------------------------- Rocky Linux ------------------------
EOF
    [ -n "$ROCKY_ISO_GNOME_X86" ] && echo "item rocky-gnome          Rocky ${ROCKY_VER_X86} (GNOME)" >> "$IPXE_FILE"
    [ -n "$ROCKY_ISO_KDE_X86" ]   && echo "item rocky-kde            Rocky ${ROCKY_VER_X86} (KDE)"   >> "$IPXE_FILE"
    [ -n "$ROCKY_ISO_XFCE_X86" ]  && echo "item rocky-xfce           Rocky ${ROCKY_VER_X86} (XFCE)"  >> "$IPXE_FILE"
fi

if [ "$ENABLE_CUSTOM_ARCHISO" = "true" ]; then
    cat >> "$IPXE_FILE" <<EOF
item --gap --             ------------------------- Arch Linux (archiso) ----------------
item arch-gnome           Arch Linux (GNOME)
item arch-kde             Arch Linux (KDE Plasma)
item arch-xfce            Arch Linux (XFCE)
item arch-sway            Arch Linux (Sway)
item arch-enlightenment   Arch Linux (Enlightenment)
EOF
fi

cat >> "$IPXE_FILE" <<EOF
item --gap --             ------------------------- Network Tools ----------------------
item netbootxyz           Netboot.xyz
item shell                iPXE Shell

choose --default local --timeout 60000 bootoption && goto \${bootoption} || goto :x86_64_menu

:local
exit

:shell
shell

:netbootxyz
chain --autofree ${NETBOOT_XYZ_URL}

:clonezilla
set cz_version 3.3.0-33-1a41a72c
set gh_base https://github.com/netbootxyz/debian-squash/releases/download/\${cz_version}
kernel \${gh_base}/vmlinuz boot=live config noswap edd=on nomodeset ocs_live_run="ocs-live-general" ocs_live_extra_param="" keyboard-layouts="" ocs_live_batch="no" locales="" vga=788 nosplash noprompt fetch=\${gh_base}/filesystem.squashfs
initrd \${gh_base}/initrd
boot || shell
EOF

if [ "$ENABLE_LOCAL_ARCH" = "true" ]; then
    cat >> "$IPXE_FILE" <<EOF
:lan-image
initrd http://${PXE_SERVER}/pxe/initramfs-linux.img
kernel http://${PXE_SERVER}/pxe/vmlinuz-linux ro initrd=initramfs-linux.img rd.neednet=1 ip=dhcp BOOTIF=01-\${mac:hexhyp} root=nbd:${PXE_SERVER%%:*}:arch
boot || shell
EOF
fi

if [ "$ENABLE_WIN11_PXE" = "true" ]; then
    cat >> "$IPXE_FILE" <<EOF
:win11-pxe
echo Booting Windows 11 from Network...
set keep-san 1
set initiator-iqn iqn.2026-02.lan.pxe:client
sanboot iscsi:${PXE_SERVER%%:*}:::0:iqn.2026-02.lan.pxe:win11 || goto shell
EOF
fi

if [ "$SKIP_DEBIAN_X86" = "false" ]; then
    cat >> "$IPXE_FILE" <<EOF

# ==================== DEBIAN (x86_64) ====================
:debian-gnome
set live_iso ${PURDUE_MIRROR}/debian-cd/current-live/amd64/iso-hybrid/debian-live-${DEBIAN_VER_X86}-amd64-gnome.iso
goto debian-boot-x86

:debian-kde
set live_iso ${PURDUE_MIRROR}/debian-cd/current-live/amd64/iso-hybrid/debian-live-${DEBIAN_VER_X86}-amd64-kde.iso
goto debian-boot-x86

:debian-xfce
set live_iso ${PURDUE_MIRROR}/debian-cd/current-live/amd64/iso-hybrid/debian-live-${DEBIAN_VER_X86}-amd64-xfce.iso
goto debian-boot-x86

:debian-boot-x86
kernel https://github.com/netbootxyz/${DEBIAN_CORE_REPO_X86}/releases/download/${DEBIAN_TAG_X86}/vmlinuz
initrd https://github.com/netbootxyz/${DEBIAN_CORE_REPO_X86}/releases/download/${DEBIAN_TAG_X86}/initrd
imgargs vmlinuz initrd=initrd boot=live fetch=\${live_iso}
boot || shell
EOF
fi

if [ "$SKIP_UBUNTU_X86" = "false" ]; then
    cat >> "$IPXE_FILE" <<EOF

# ==================== UBUNTU LTS (x86_64) ====================
:ubuntu-gnome
set live_iso ${PURDUE_MIRROR}/ubuntu-releases/${UBUNTU_VER_X86}/${UBUNTU_ISO_X86}
kernel https://github.com/netbootxyz/ubuntu-squash/releases/download/${UBUNTU_TAG_X86}/vmlinuz
initrd https://github.com/netbootxyz/ubuntu-squash/releases/download/${UBUNTU_TAG_X86}/initrd
imgargs vmlinuz initrd=initrd boot=casper netboot=url url=\${live_iso} ip=dhcp ---
boot || shell
EOF
fi

if [ "$SKIP_FEDORA_X86" = "false" ]; then
    echo "" >> "$IPXE_FILE"
    echo "# ==================== FEDORA (x86_64) ====================" >> "$IPXE_FILE"
    if [ -n "$FEDORA_ISO_GNOME_X86" ]; then
        printf ':fedora-gnome\nset iso_name %s\nset flavor_dir %s\ngoto fedora-boot-x86\n\n' "$FEDORA_ISO_GNOME_X86" "$FEDORA_DIR_GNOME_X86" >> "$IPXE_FILE"
    fi
    if [ -n "$FEDORA_ISO_KDE_X86" ]; then
        printf ':fedora-kde\nset iso_name %s\nset flavor_dir %s\ngoto fedora-boot-x86\n\n' "$FEDORA_ISO_KDE_X86" "$FEDORA_DIR_KDE_X86" >> "$IPXE_FILE"
    fi
    if [ -n "$FEDORA_ISO_XFCE_X86" ]; then
        printf ':fedora-xfce\nset iso_name %s\nset flavor_dir %s\ngoto fedora-boot-x86\n\n' "$FEDORA_ISO_XFCE_X86" "$FEDORA_DIR_XFCE_X86" >> "$IPXE_FILE"
    fi
    cat >> "$IPXE_FILE" <<EOF
:fedora-boot-x86
set mirror ${FEDORA_MIRROR_BASE}/${FEDORA_VER_X86}/Server/x86_64/os
set live_url ${FEDORA_MIRROR_BASE}/${FEDORA_VER_X86}/\${flavor_dir}/x86_64/iso/\${iso_name}
kernel \${mirror}/images/pxeboot/vmlinuz
initrd \${mirror}/images/pxeboot/initrd.img
imgargs vmlinuz initrd=initrd.img root=live:\${live_url} rd.live.image rd.live.overlay.overlayfs=1 ip=dhcp
boot || shell
EOF
fi

if [ "$SKIP_ROCKY_X86" = "false" ]; then
    echo "" >> "$IPXE_FILE"
    echo "# ==================== ROCKY (x86_64) ====================" >> "$IPXE_FILE"
    if [ -n "$ROCKY_ISO_GNOME_X86" ]; then
        printf ':rocky-gnome\nset iso_name %s\ngoto rocky-boot-x86\n\n' "$ROCKY_ISO_GNOME_X86" >> "$IPXE_FILE"
    fi
    if [ -n "$ROCKY_ISO_KDE_X86" ]; then
        printf ':rocky-kde\nset iso_name %s\ngoto rocky-boot-x86\n\n' "$ROCKY_ISO_KDE_X86" >> "$IPXE_FILE"
    fi
    if [ -n "$ROCKY_ISO_XFCE_X86" ]; then
        printf ':rocky-xfce\nset iso_name %s\ngoto rocky-boot-x86\n\n' "$ROCKY_ISO_XFCE_X86" >> "$IPXE_FILE"
    fi
    cat >> "$IPXE_FILE" <<EOF
:rocky-boot-x86
set mirror ${PURDUE_MIRROR}/rocky/${ROCKY_VER_X86}/BaseOS/x86_64/os
set live_url ${PURDUE_MIRROR}/rocky/${ROCKY_VER_X86}/${ROCKY_LIVE_DIR_X86}/x86_64/\${iso_name}
kernel \${mirror}/images/pxeboot/vmlinuz
initrd \${mirror}/images/pxeboot/initrd.img
imgargs vmlinuz initrd=initrd.img root=live:\${live_url} rd.live.image rd.live.overlay.overlayfs=1 ip=dhcp
boot || shell
EOF
fi

# ==================== ARCH LINUX (ARCHISO) ====================
if [ "$ENABLE_CUSTOM_ARCHISO" = "true" ]; then
    cat >> "$IPXE_FILE" <<EOF
:arch-common
# Artifacts are in http://<server>/pxe/archiso/
# We extracted vmlinuz-linux and initramfs-linux.img to the root of archiso/ during build
set arch_http http://${PXE_SERVER}/pxe/archiso
set arch_iso_label ARCH_$(date +%Y%m)

kernel \${arch_http}/vmlinuz-linux
initrd \${arch_http}/initramfs-linux.img
# archisobasedir matches the directory inside the ISO (default: arch)
# archisolabel must match the one in profiledef.sh (ARCH_YYYYMM)
# We use archiso_http_srv to point to the directory containing the ISO or extracted files
# If booting from valid copy-to-ram ISO, we might need imgargs adjustment.
# For now, pointing to the folder.
imgargs vmlinuz-linux initrd=initramfs-linux.img archisobasedir=arch archisolabel=\${arch_iso_label} archiso_http_srv=\${arch_http}/ desktop=\${desktop_env} ip=dhcp BOOTIF=01-\${mac:hexhyp} cow_spacesize=4G copytoram=n
boot || shell

:arch-gnome
set desktop_env gnome
goto arch-common

:arch-kde
set desktop_env kde
goto arch-common

:arch-xfce
set desktop_env xfce
goto arch-common

:arch-sway
set desktop_env sway
goto arch-common

:arch-enlightenment
set desktop_env enlightenment
goto arch-common
EOF
fi

# ============================================================================
#                               ARM64 LABELS
# ============================================================================
# Only add labels if versions were found, to avoid clutter and broken links.
# DEBIAN ARM
if [ -n "$DEBIAN_VER_ARM" ]; then
    cat >> "$IPXE_FILE" <<EOF

:debian-gnome-arm
set live_iso ${PURDUE_MIRROR}/debian-cd/current-live/arm64/iso-hybrid/debian-live-${DEBIAN_VER_ARM}-arm64-gnome.iso
kernel https://github.com/netbootxyz/${DEBIAN_CORE_REPO_ARM}/releases/download/${DEBIAN_TAG_ARM}/vmlinuz
initrd https://github.com/netbootxyz/${DEBIAN_CORE_REPO_ARM}/releases/download/${DEBIAN_TAG_ARM}/initrd
imgargs vmlinuz initrd=initrd boot=live fetch=\${live_iso}
boot || shell
EOF
fi

echo "Done! Generated $IPXE_FILE"

# ==========================================
# 7. Post-generation URL Validation
# ==========================================
# HEAD-check every absolute URL referenced from the generated iPXE file.
# Reports broken links but does not exit non-zero — the script must remain
# usable when one upstream is temporarily down.
echo "Validating embedded URLs..."
# Capture URL tokens including any iPXE-time-evaluated ${var} sections,
# then drop any URL that contains an unresolved variable — those can only be
# checked at boot time, not at script-generation time.
mapfile -t URLS < <(grep -oE 'https?://[^[:space:]"]+' "$IPXE_FILE" \
    | grep -v "boot.netboot.xyz" \
    | grep -v -F '${' \
    | sort -u)

BROKEN=0
for url in "${URLS[@]}"; do
    if check_url_exists "$url"; then
        :
    else
        echo "  [BROKEN] $url"
        BROKEN=$((BROKEN + 1))
    fi
done
if [ "$BROKEN" -eq 0 ]; then
    echo "  All ${#URLS[@]} URLs reachable."
else
    echo "  [WARNING] ${BROKEN} of ${#URLS[@]} URLs failed validation. The iPXE menu may have boot failures for those entries."
fi
