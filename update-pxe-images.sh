#!/bin/bash
set -e

# ==========================================
# Configuration Variables
# ==========================================
PXE_SERVER="192.168.1.11:81"
PXE_HTTP_DIR="/srv/http/pxe"
TFTP_DIR="/srv/tftp"

ENABLE_LOCAL_ARCH="false"        # Set to "true" to copy local Arch Kernel/Initrd
ENABLE_TFTP_BOOTSTRAP="false"    # Set to "true" to download iPXE binaries to TFTP_DIR
ENABLE_CUSTOM_ARCHISO="false"    # Set to "true" to enable Custom Archiso Menu

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
    if curl -sI "$url" | head -n 1 | grep -q "200"; then
        return 0
    else
        return 1
    fi
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
get_fedora_iso() {
    local ver=$1
    local variant=$2 # gnome (Workstation), kde, xfce
    local arch=$3    # x86_64, aarch64
    
    local url_base="${FEDORA_MIRROR_BASE}/${ver}"
    local iso_pattern=""
    local flavor_dir=""

    case "$variant" in
        gnome)
            flavor_dir="Workstation"
            iso_pattern="Fedora-Workstation-Live-[^\"]*${arch}\.iso"
            ;;
        kde)
            flavor_dir="Spins"
            iso_pattern="Fedora-KDE-Live-[^\"]*${arch}\.iso"
            ;;
        xfce)
            flavor_dir="Spins"
            iso_pattern="Fedora-Xfce-Live-[^\"]*${arch}\.iso"
            ;;
    esac

    curl -sL "${url_base}/${flavor_dir}/${arch}/iso/" | grep -oP "$iso_pattern" | head -n 1
}

# --- Rocky ---
get_rocky_version() {
    local arch=$1 # x86_64, aarch64
    # Regex updated to [\d\.]+ to capture 10.1, 10.2 etc.
    local versions=$(curl -sL "${PURDUE_MIRROR}/rocky/" | grep -oP 'href="\K[\d\.]+(?=/")' | sort -rV)
    for ver in $versions; do
        for dir in "live" "Live"; do
            if check_url_exists "${PURDUE_MIRROR}/rocky/${ver}/${dir}/${arch}/"; then
                echo "$ver"
                return 0
            fi
        done
    done
    echo ""
}
get_rocky_iso() {
    local ver=$1
    local variant=$2 # gnome (Workstation), kde, xfce
    local arch=$3    # x86_64, aarch64
    local live_dir="live"
    
    # Check casing
    if ! check_url_exists "${PURDUE_MIRROR}/rocky/${ver}/live/${arch}/"; then
        live_dir="Live"
    fi

    local iso_pattern=""
    case "$variant" in
        gnome) iso_pattern="href=\"\KRocky-[\d\.\-]+-Workstation(-Live)?-${arch}[^\"]*\.iso" ;;
        kde)   iso_pattern="href=\"\KRocky-[\d\.\-]+-KDE(-Live)?-${arch}[^\"]*\.iso" ;;
        xfce)  iso_pattern="href=\"\KRocky-[\d\.\-]+-XFCE(-Live)?-${arch}[^\"]*\.iso" ;;
    esac
    
    curl -sL "${PURDUE_MIRROR}/rocky/${ver}/${live_dir}/${arch}/" | grep -oP "$iso_pattern" | head -n 1
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
    echo "Updating Local Arch Linux files..."
    if [ -f /boot/vmlinuz-linux ]; then
        cp -f /boot/vmlinuz-linux "$PXE_HTTP_DIR/vmlinuz-linux"
        cp -f /boot/initramfs-linux.img "$PXE_HTTP_DIR/initramfs-linux.img"
        chmod 644 "$PXE_HTTP_DIR/vmlinuz-linux" "$PXE_HTTP_DIR/initramfs-linux.img"
        echo "  Copied from /boot."
    else
        echo "  [WARNING] /boot/vmlinuz-linux not found."
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

DEBIAN_VER_X86=$(get_debian_version "amd64")
echo "  Debian (x86_64):  $DEBIAN_VER_X86"

FEDORA_VER_X86=$(get_fedora_version "x86_64")
FEDORA_ISO_GNOME_X86=$(get_fedora_iso "$FEDORA_VER_X86" "gnome" "x86_64")
FEDORA_ISO_KDE_X86=$(get_fedora_iso "$FEDORA_VER_X86" "kde" "x86_64")
FEDORA_ISO_XFCE_X86=$(get_fedora_iso "$FEDORA_VER_X86" "xfce" "x86_64")
echo "  Fedora (x86_64):  $FEDORA_VER_X86 (G: $FEDORA_ISO_GNOME_X86)"

ROCKY_VER_X86=$(get_rocky_version "x86_64")
ROCKY_ISO_GNOME_X86=$(get_rocky_iso "$ROCKY_VER_X86" "gnome" "x86_64")
ROCKY_ISO_KDE_X86=$(get_rocky_iso "$ROCKY_VER_X86" "kde" "x86_64")
ROCKY_ISO_XFCE_X86=$(get_rocky_iso "$ROCKY_VER_X86" "xfce" "x86_64")
echo "  Rocky (x86_64):   $ROCKY_VER_X86 (G: $ROCKY_ISO_GNOME_X86)"

# ==========================================
# 5. Version Scrape (ARM64)
# ==========================================
echo "Detecting ARM64 Versions..."

DEBIAN_VER_ARM=$(get_debian_version "arm64")
echo "  Debian (ARM64):  ${DEBIAN_VER_ARM:-Skipped}"

FEDORA_VER_ARM=$(get_fedora_version "aarch64")
if [ -n "$FEDORA_VER_ARM" ]; then
    FEDORA_ISO_GNOME_ARM=$(get_fedora_iso "$FEDORA_VER_ARM" "gnome" "aarch64")
    FEDORA_ISO_KDE_ARM=$(get_fedora_iso "$FEDORA_VER_ARM" "kde" "aarch64")
    FEDORA_ISO_XFCE_ARM=$(get_fedora_iso "$FEDORA_VER_ARM" "xfce" "aarch64")
    if [ -z "$FEDORA_ISO_GNOME_ARM" ] && [ -z "$FEDORA_ISO_KDE_ARM" ] && [ -z "$FEDORA_ISO_XFCE_ARM" ]; then
         FEDORA_VER_ARM="" # No ISOs found
    fi
fi
echo "  Fedora (ARM64):  ${FEDORA_VER_ARM:-Skipped}"

ROCKY_VER_ARM=$(get_rocky_version "aarch64")
if [ -n "$ROCKY_VER_ARM" ]; then
    ROCKY_ISO_GNOME_ARM=$(get_rocky_iso "$ROCKY_VER_ARM" "gnome" "aarch64")
    ROCKY_ISO_KDE_ARM=$(get_rocky_iso "$ROCKY_VER_ARM" "kde" "aarch64")
    ROCKY_ISO_XFCE_ARM=$(get_rocky_iso "$ROCKY_VER_ARM" "xfce" "aarch64")
    if [ -z "$ROCKY_ISO_GNOME_ARM" ] && [ -z "$ROCKY_ISO_KDE_ARM" ] && [ -z "$ROCKY_ISO_XFCE_ARM" ]; then
         ROCKY_VER_ARM=""
    fi
fi
echo "  Rocky (ARM64):   ${ROCKY_VER_ARM:-Skipped}"

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

cat >> "$IPXE_FILE" <<EOF
item --gap --             ------------------------- Debian Live ------------------------
item debian-gnome         Debian ${DEBIAN_VER_X86} (GNOME)
item debian-kde           Debian ${DEBIAN_VER_X86} (KDE)
item debian-xfce          Debian ${DEBIAN_VER_X86} (XFCE)
item --gap --             ------------------------- Fedora Live ------------------------
item fedora-gnome         Fedora ${FEDORA_VER_X86} (GNOME)
item fedora-kde           Fedora ${FEDORA_VER_X86} (KDE)
item fedora-xfce          Fedora ${FEDORA_VER_X86} (XFCE)
item --gap --             ------------------------- Rocky Linux ------------------------
item rocky-gnome          Rocky ${ROCKY_VER_X86} (GNOME)
item rocky-kde            Rocky ${ROCKY_VER_X86} (KDE)
item rocky-xfce           Rocky ${ROCKY_VER_X86} (XFCE)
EOF

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
kernel http://${PXE_SERVER}/pxe/vmlinuz-linux ro initrd=initramfs-linux.img ip=dhcp BOOTIF=01-\${mac:hexhyp} nbd_host=${PXE_SERVER%%:*} nbd_name=arch root=/dev/nbd0
boot || shell
EOF
fi

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
kernel https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_X86}-92911322/vmlinuz || kernel https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_X86}/vmlinuz
initrd https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_X86}-92911322/initrd || initrd https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_X86}/initrd
imgargs vmlinuz initrd=initrd boot=live fetch=\${live_iso}
boot || shell

# ==================== FEDORA (x86_64) ====================
:fedora-gnome
set iso_name ${FEDORA_ISO_GNOME_X86}
set flavor_dir Workstation
goto fedora-boot-x86

:fedora-kde
set iso_name ${FEDORA_ISO_KDE_X86}
set flavor_dir Spins
goto fedora-boot-x86

:fedora-xfce
set iso_name ${FEDORA_ISO_XFCE_X86}
set flavor_dir Spins
goto fedora-boot-x86

:fedora-boot-x86
set mirror ${FEDORA_MIRROR_BASE}/${FEDORA_VER_X86}/Server/x86_64/os
set live_url ${FEDORA_MIRROR_BASE}/${FEDORA_VER_X86}/\${flavor_dir}/x86_64/iso/\${iso_name}
kernel \${mirror}/images/pxeboot/vmlinuz
initrd \${mirror}/images/pxeboot/initrd.img
imgargs vmlinuz initrd=initrd.img root=live:\${live_url} rd.live.image rd.live.overlay.overlayfs=1 ip=dhcp
boot || shell

# ==================== ROCKY (x86_64) ====================
:rocky-gnome
set iso_name ${ROCKY_ISO_GNOME_X86}
goto rocky-boot-x86

:rocky-kde
set iso_name ${ROCKY_ISO_KDE_X86}
goto rocky-boot-x86

:rocky-xfce
set iso_name ${ROCKY_ISO_XFCE_X86}
goto rocky-boot-x86

:rocky-boot-x86
set mirror ${PURDUE_MIRROR}/rocky/${ROCKY_VER_X86}/BaseOS/x86_64/os
# Rocky Live path upper/lowercase check was done in scraping, assuming 'live' or standardizing for config
# For robustness we try standard 'live' or assume user wont change mirror struct frequently
set live_url ${PURDUE_MIRROR}/rocky/${ROCKY_VER_X86}/live/x86_64/\${iso_name}
kernel \${mirror}/images/pxeboot/vmlinuz
initrd \${mirror}/images/pxeboot/initrd.img
imgargs vmlinuz initrd=initrd.img root=live:\${live_url} rd.live.image rd.live.overlay.overlayfs=1 ip=dhcp
boot || shell
EOF

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
# Use Netboot assets if available (likely need specific ARM64 build assets)
# Netboot.xyz debian-squash usually supports arm64 if tagged.
kernel https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_ARM}-92911322/vmlinuz || kernel https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_ARM}/vmlinuz
initrd https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_ARM}-92911322/initrd || initrd https://github.com/netbootxyz/debian-squash/releases/download/${DEBIAN_VER_ARM}/initrd
imgargs vmlinuz initrd=initrd boot=live fetch=\${live_iso}
boot || shell
EOF
fi

echo "Done! Generated $IPXE_FILE"
