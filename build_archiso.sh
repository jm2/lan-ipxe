#!/bin/bash
set -e

# ==========================================
# Configuration
# ==========================================
BASE_DIR="$(dirname "$(realpath "$0")")"
PROFILE_DIR="$BASE_DIR/custom_archiso"

# ISO filesystem label, captured ONCE here.
# The same value is forced into profiledef.sh (iso_label) so it is baked into
# the ISO at build time AND written to iso_label.txt for the PXE menu generator.
# This guarantees the on-disk label and the recorded label always agree.
# (releng default recomputes ARCH_$(date +%Y%m) at build time; the menu
# generator must read iso_label.txt instead of recomputing the date itself,
# which would drift across a month boundary and break archisolabel matching.)
ISO_LABEL="ARCH_$(date +%Y%m)"

if [ -w "/media/r0/tmp" ]; then
    WORK_DIR="/media/r0/tmp/archiso-work"
else
    WORK_DIR="/var/tmp/archiso-work"
fi

# Remove the (tens of GB) work tree and the generated profile on ANY exit,
# including a mkarchiso/cp failure under `set -e`. Without this a failed build
# strands the work tree -- and /media/r0/tmp does not exist on every host, so
# WORK_DIR usually falls back to /var/tmp on the root filesystem.
trap 'rm -rf "$WORK_DIR" "$PROFILE_DIR"' EXIT

# Output Directory Logic
if [ -w "/srv/http/pxe" ]; then
    OUT_DIR="/srv/http/pxe/archiso"
else
    OUT_DIR="$BASE_DIR/archiso"
fi

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "========================================"
echo " Archiso Builder"
echo "========================================"
echo "Base Dir:    $BASE_DIR"
echo "Profile Dir: $PROFILE_DIR (Generated)"
echo "Work Dir:    $WORK_DIR"
echo "Out Dir:     $OUT_DIR"
echo "========================================"

# ==========================================
# 1. Prepare Profile
# ==========================================
echo "Creating custom profile from releng skeleton..."
rm -rf "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR"
# Copy stock releng profile
cp -r /usr/share/archiso/configs/releng/* "$PROFILE_DIR/"

# ==========================================
# 2. Customize Configuration
# ==========================================

# ------------------------------------------------------------------------
# CLIENT-RAM / BOOT-TRANSPORT NOTES (read before changing the package set)
# ------------------------------------------------------------------------
# This airootfs bundles FIVE desktop environments (GNOME, KDE Plasma, XFCE,
# Sway, Enlightenment) plus a full toolchain (base-devel, clang, llvm, cmake,
# dkms, kernel headers, graphics stacks). The resulting squashfs is large.
#
# HTTP PXE boot caveat: the archiso_pxe_http hook ALWAYS pulls the whole
# squashfs over HTTP into a tmpfs and archiso then copies it again into the
# cow/sfs space -- i.e. it effectively behaves as copytoram and IGNORES
# copytoram=n, and (due to an upstream defect) holds roughly 2x the squashfs
# size in RAM during early boot. Practical client RAM floor is about
#     2 x (squashfs size) + working memory
# so for this multi-DE image only large-RAM clients can HTTP-boot it.
#
# Recommendation: prefer NFS or NBD serving for this image. The initramfs
# already carries archiso_pxe_nfs and archiso_pxe_nbd hooks (see the HOOKS line
# further down); those mount the rootfs over the network instead of copying it
# into RAM, removing the RAM floor. (The PXE menu already exposes an NBD entry.)
#
# Tunable: if HTTP boot is unavoidable, archiso_http_spc bounds the tmpfs used
# for the downloaded squashfs (default ~75% of RAM); cow_spacesize /
# copytoram_size bound the writable overlay. None of these remove the ~2x copy,
# so NFS/NBD remains the real fix. The package set is intentionally UNCHANGED.
# ------------------------------------------------------------------------

# --- Packages ---
echo "Adding custom packages..."
cat >> "$PROFILE_DIR/packages.x86_64" <<EOF
# Custom Packages
haveged
rng-tools
polkit
gnome-keyring
7zip
alsa-firmware
sof-firmware
alsa-oss
alsa-plugins
pipewire-alsa
archiso
bash-completion
clang
cmake
colordiff
cronie
dkms
flashrom
gcc
gcc-libs
gsmartcontrol
gst-plugin-va
gst-plugins-ugly
htop
iperf
iperf3
linux-headers
llvm
mediainfo
meld
base-devel
vim
networkmanager
openssh
git
firefox
chromium
rsync
gparted
# GNOME
gnome
gnome-extra
gdm
# KDE Plasma
plasma
kde-applications
sddm
# XFCE
xfce4
xfce4-goodies
lightdm
lightdm-gtk-greeter
# Sway
sway
swaybg
swayidle
swaylock
waybar
foot
# Enlightenment
enlightenment
terminology
# Graphics Drivers
nvidia-open
nvidia-utils
mesa
mesa-utils
vulkan-radeon
vulkan-intel
vulkan-nouveau
vulkan-swrast
vulkan-virtio
vulkan-mesa-layers
libva-intel-driver
intel-media-driver
libva-nvidia-driver
xf86-video-amdgpu
xf86-video-intel
xf86-video-nouveau
xf86-video-vesa
wayland
xorg-server
xorg-xinit
EOF

# --- Pacman Config (Mirrors) ---
echo "Configuring mirrors..."
# Replace Includes with Hardcoded RCAC Mirror for [core] and [extra]
# We use a loop/sed to be robust
sed -i 's|^Include = /etc/pacman.d/mirrorlist|Server = https://plug-mirror.rcac.purdue.edu/archlinux/$repo/os/$arch|' "$PROFILE_DIR/pacman.conf"
# Also handle commented out ones if needed, but releng has them enabled by default.
grep -q '^Server = https://plug-mirror.rcac.purdue.edu/archlinux' "$PROFILE_DIR/pacman.conf" || { echo "[-] pacman.conf mirror patch failed (Include line not found)"; exit 1; }

# --- Profile Definition ---
# Each sed below is an exact-string patch against the upstream releng file and
# would silently no-op if upstream renamed/reformatted the target. Assert each
# landed so a stale skeleton fails the build loudly instead of shipping a
# half-customized ISO.
echo "Updating profile definition..."
sed -i 's|iso_name="archlinux"|iso_name="archlinux-custom"|' "$PROFILE_DIR/profiledef.sh"
grep -q 'iso_name="archlinux-custom"' "$PROFILE_DIR/profiledef.sh" || { echo "[-] profiledef.sh iso_name patch failed"; exit 1; }

# Pin a stable ISO label. The releng default is iso_label="ARCH_$(date +%Y%m)",
# which mkarchiso would re-evaluate at build time; force the literal captured in
# $ISO_LABEL so the baked-in label matches what we record in iso_label.txt.
sed -i "s|^iso_label=.*|iso_label=\"${ISO_LABEL}\"|" "$PROFILE_DIR/profiledef.sh"
grep -q "iso_label=\"${ISO_LABEL}\"" "$PROFILE_DIR/profiledef.sh" || { echo "[-] profiledef.sh iso_label patch failed"; exit 1; }

# Switch to zstd compression for faster build
sed -i "s|airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')|airootfs_image_tool_options=('-comp' 'zstd' '-b' '1M')|" "$PROFILE_DIR/profiledef.sh"
grep -qF "airootfs_image_tool_options=('-comp' 'zstd' '-b' '1M')" "$PROFILE_DIR/profiledef.sh" || { echo "[-] profiledef.sh compression-options patch failed"; exit 1; }

# Add permissions for our custom scripts.
# Anchor to the file_permissions array's opening line and APPEND after it,
# rather than inserting before "any column-1 )" which could match an unrelated
# array close. (Verified: the array is named file_permissions in releng.)
sed -i '/^file_permissions=(/a \  ["/usr/local/bin/configure-desktop.sh"]="0:0:755"' "$PROFILE_DIR/profiledef.sh"
grep -qF '["/usr/local/bin/configure-desktop.sh"]="0:0:755"' "$PROFILE_DIR/profiledef.sh" || { echo "[-] profiledef.sh configure-desktop.sh permission insert failed"; exit 1; }
sed -i '/^file_permissions=(/a \  ["/usr/lib/systemd/system-generators/archiso-desktop-generator"]="0:0:755"' "$PROFILE_DIR/profiledef.sh"
grep -qF '["/usr/lib/systemd/system-generators/archiso-desktop-generator"]="0:0:755"' "$PROFILE_DIR/profiledef.sh" || { echo "[-] profiledef.sh archiso-desktop-generator permission insert failed"; exit 1; }

# ==========================================
# 3. Inject Custom Files
# ==========================================
echo "Injecting custom scripts and configs..."

# --- archiso-desktop-generator ---
mkdir -p "$PROFILE_DIR/airootfs/usr/lib/systemd/system-generators"
cat > "$PROFILE_DIR/airootfs/usr/lib/systemd/system-generators/archiso-desktop-generator" <<'EOF'
#!/bin/sh

# Generator for desktop selection
# Arguments: normal-dir early-dir late-dir
NORMAL_DIR="$1"

# Parse cmdline
for arg in $(cat /proc/cmdline); do
    case $arg in
        desktop=*)
            DESKTOP="${arg#*=}"
            ;;
    esac
done

# Default to gnome if not set
if [ -z "$DESKTOP" ]; then
   DESKTOP="gnome"
fi

# Determine service based on desktop
case "$DESKTOP" in
    gnome) DM="gdm" ;;
    kde|plasma) DM="sddm" ;;
    xfce) DM="lightdm" ;;
    sway) DM="sddm" ;;
    enlightenment) DM="sddm" ;;
    *) DM="" ;;
esac

if [ -n "$DM" ]; then
    # Create symlink to enable the display manager
    mkdir -p "$NORMAL_DIR"
    ln -sf "/usr/lib/systemd/system/$DM.service" "$NORMAL_DIR/display-manager.service"
    
    # Set default target to graphical
    ln -sf "/usr/lib/systemd/system/graphical.target" "$NORMAL_DIR/default.target"
fi
EOF
chmod +x "$PROFILE_DIR/airootfs/usr/lib/systemd/system-generators/archiso-desktop-generator"

# --- configure-desktop.sh ---
mkdir -p "$PROFILE_DIR/airootfs/usr/local/bin"
cat > "$PROFILE_DIR/airootfs/usr/local/bin/configure-desktop.sh" <<'EOF'
#!/bin/bash

# Parse cmdline to get desktop choice for autologin config
for arg in $(cat /proc/cmdline); do
    case $arg in
        desktop=*)
            DESKTOP="${arg#*=}"
            ;;
    esac
done

if [ -z "$DESKTOP" ]; then
    DESKTOP="gnome"
fi

configure_live_user() {
    if ! id "live" &>/dev/null; then
        useradd -m -G wheel -s /bin/bash live
        echo "live:live" | chpasswd
    fi
    echo 'live ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/live
    chmod 440 /etc/sudoers.d/live
}

configure_autologin() {
    local dm=$1
    echo "Configuring autologin for $dm..."
    case $dm in
        gdm)
            mkdir -p /etc/gdm
            cat > /etc/gdm/custom.conf <<CONF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=live
CONF
            ;;
        sddm)
            mkdir -p /etc/sddm.conf.d
            cat > /etc/sddm.conf.d/autologin.conf <<CONF
[Autologin]
User=live
Session=plasma
CONF
            if [ "$DESKTOP" == "sway" ]; then
                sed -i 's/Session=plasma/Session=sway/' /etc/sddm.conf.d/autologin.conf
            elif [ "$DESKTOP" == "enlightenment" ]; then
                sed -i 's/Session=plasma/Session=enlightenment/' /etc/sddm.conf.d/autologin.conf
            fi
            ;;
        lightdm)
            cat >> /etc/lightdm/lightdm.conf <<CONF
[Seat:*]
autologin-user=live
autologin-session=xfce
CONF
            ;;
    esac
}

configure_live_user

# Identify DM to configure autologin
case "$DESKTOP" in
    gnome) configure_autologin gdm ;;
    kde|plasma) configure_autologin sddm ;;
    xfce) configure_autologin lightdm ;;
    sway) configure_autologin sddm ;;
    enlightenment) configure_autologin sddm ;;
esac
EOF
chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/configure-desktop.sh"

# --- configure-desktop.service ---
mkdir -p "$PROFILE_DIR/airootfs/etc/systemd/system"
cat > "$PROFILE_DIR/airootfs/etc/systemd/system/configure-desktop.service" <<EOF
[Unit]
Description=Configure Desktop Autologin
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/configure-desktop.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Symlink service and haveged
mkdir -p "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants"
ln -sf ../configure-desktop.service "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants/configure-desktop.service"
ln -sf /usr/lib/systemd/system/haveged.service "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants/haveged.service"

# --- mkinitcpio.conf (Modules/Hooks) ---
mkdir -p "$PROFILE_DIR/airootfs/etc/mkinitcpio.conf.d"
cat > "$PROFILE_DIR/airootfs/etc/mkinitcpio.conf.d/archiso.conf" <<EOF
HOOKS=(base udev microcode modconf kms memdisk archiso archiso_loop_mnt archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs block filesystems keyboard)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=()
EOF

# --- passwd (Root shell) ---
cat > "$PROFILE_DIR/airootfs/etc/passwd" <<EOF
root:x:0:0:root:/root:/usr/bin/bash
EOF

# ==========================================
# 4. Build
# ==========================================
echo "Starting build..."
mkdir -p "$OUT_DIR"

# Prune previously built ISOs. mkarchiso emits a fresh dated
# archlinux-custom-<version>-x86_64.iso into OUT_DIR on every run and never
# cleans them up, so they accumulate. The PXE flow only consumes the extracted
# vmlinuz-linux, initramfs-linux.img and airootfs.sfs (copied to fixed names
# below), so the ISO images are dead weight -- remove them. The glob is anchored
# to the archlinux-custom- prefix inside OUT_DIR only; rm -f is a no-op when
# nothing matches (the unexpanded glob is silently ignored).
rm -f "$OUT_DIR"/archlinux-custom-*.iso

# Cleaning work dir (before build)
rm -rf "$WORK_DIR"

# Precheck free space on the chosen WORK_DIR filesystem before mkarchiso runs a
# full pacstrap + squashfs build, so we abort with a clear message instead of
# dying mid-build with ENOSPC and stranding a partial work tree.
WORK_PARENT="$(dirname "$WORK_DIR")"
MIN_FREE_KB=$((50 * 1024 * 1024))   # ~50 GiB
AVAIL_KB="$(df --output=avail -k "$WORK_PARENT" | tail -n1 | tr -d '[:space:]')"
if [ -z "$AVAIL_KB" ] || [ "$AVAIL_KB" -lt "$MIN_FREE_KB" ]; then
    echo "[-] Not enough free space on $WORK_PARENT for the build."
    echo "    Required: ~50 GiB; available: $(( ${AVAIL_KB:-0} / 1024 / 1024 )) GiB."
    exit 1
fi

mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

# Copy Kernel and Initrd to OUT_DIR for PXE
echo "Copying kernel and initrd to $OUT_DIR..."
cp "$WORK_DIR/iso/arch/boot/x86_64/vmlinuz-linux" "$OUT_DIR/"
cp "$WORK_DIR/iso/arch/boot/x86_64/initramfs-linux.img" "$OUT_DIR/"

# Copy airootfs.sfs (Required for HTTP Boot)
echo "Copying airootfs.sfs to $OUT_DIR/arch/x86_64/..."
mkdir -p "$OUT_DIR/arch/x86_64"
cp "$WORK_DIR/iso/arch/x86_64/airootfs.sfs" "$OUT_DIR/arch/x86_64/"
# Note: airootfs.sha512 is NOT used by the PXE flow unless the menu passes
# checksum=y on the kernel cmdline; copied here only for completeness.
cp "$WORK_DIR/iso/arch/x86_64/airootfs.sha512" "$OUT_DIR/arch/x86_64/"

# Record the authoritative ISO label for the PXE menu generator.
# update-pxe-images.sh reads this file to set archisolabel=... instead of
# recomputing $(date +%Y%m) at menu-generation time (which drifts across month
# boundaries and breaks the label match). vmlinuz-linux / initramfs-linux.img
# are copied to OUT_DIR (served at http://<server>/pxe/archiso/), so the label
# file sits alongside them at OUT_DIR/iso_label.txt.
echo "$ISO_LABEL" > "$OUT_DIR/iso_label.txt"
echo "Recorded ISO label '$ISO_LABEL' to $OUT_DIR/iso_label.txt"

# Work dir and profile dir are removed by the EXIT trap installed near the top.
echo "Build Complete!"
