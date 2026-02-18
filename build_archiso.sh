#!/bin/bash
set -e

# ==========================================
# Configuration
# ==========================================
BASE_DIR="$(dirname "$(realpath "$0")")"
PROFILE_DIR="$BASE_DIR/custom_archiso"
WORK_DIR="/var/tmp/archiso-work"

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

# --- Packages ---
echo "Adding custom packages..."
cat >> "$PROFILE_DIR/packages.x86_64" <<EOF
# Custom Packages
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
vulkan-radeon
vulkan-intel
vulkan-mesa-layers
libva-mesa-driver
xf86-video-amdgpu
xf86-video-intel
xf86-video-nouveau
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

# --- Profile Definition ---
echo "Updating profile definition..."
sed -i 's|iso_name="archlinux"|iso_name="archlinux-custom"|' "$PROFILE_DIR/profiledef.sh"
# Switch to zstd compression for faster build
sed -i "s|airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')|airootfs_image_tool_options=('-comp' 'zstd' '-b' '1M')|" "$PROFILE_DIR/profiledef.sh"

# Add permissions for our custom scripts
# Insert before the closing parenthesis of file_permissions
sed -i '/^)/i \  ["/usr/local/bin/choose-desktop.sh"]="0:0:755"' "$PROFILE_DIR/profiledef.sh"

# ==========================================
# 3. Inject Custom Files
# ==========================================
echo "Injecting custom scripts and configs..."

# --- choose-desktop.sh ---
mkdir -p "$PROFILE_DIR/airootfs/usr/local/bin"
cat > "$PROFILE_DIR/airootfs/usr/local/bin/choose-desktop.sh" <<'EOF'
#!/bin/bash

# Parse cmdline
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

echo "Selected Desktop: $DESKTOP"

enable_dm() {
    local dm=$1
    echo "Enabling $dm..."
    systemctl enable "$dm.service" --force
    systemctl set-default graphical.target
}

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

case "$DESKTOP" in
    gnome) enable_dm gdm; configure_autologin gdm ;;
    kde|plasma) enable_dm sddm; configure_autologin sddm ;;
    xfce) enable_dm lightdm; configure_autologin lightdm ;;
    sway) enable_dm sddm; configure_autologin sddm ;;
    enlightenment) enable_dm sddm; configure_autologin sddm ;;
    *) echo "Unknown desktop. Fallback to multi-user."; systemctl set-default multi-user.target ;;
esac

if [ "$DESKTOP" != "unknown" ]; then
    systemctl isolate graphical.target
fi
EOF
chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/choose-desktop.sh"

# --- choose-desktop.service ---
mkdir -p "$PROFILE_DIR/airootfs/etc/systemd/system"
cat > "$PROFILE_DIR/airootfs/etc/systemd/system/choose-desktop.service" <<EOF
[Unit]
Description=Choose Desktop Environment based on Kernel cmdline
Before=display-manager.service
After=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/choose-desktop.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Symlink service
mkdir -p "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants"
ln -sf ../choose-desktop.service "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants/choose-desktop.service"

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

# Cleaning work dir (before build)
rm -rf "$WORK_DIR"

mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

# Copy Kernel and Initrd to OUT_DIR for PXE
echo "Copying kernel and initrd to $OUT_DIR..."
cp "$WORK_DIR/iso/arch/boot/x86_64/vmlinuz-linux" "$OUT_DIR/"
cp "$WORK_DIR/iso/arch/boot/x86_64/initramfs-linux.img" "$OUT_DIR/"

# Copy airootfs.sfs (Required for HTTP Boot)
echo "Copying airootfs.sfs to $OUT_DIR/arch/x86_64/..."
mkdir -p "$OUT_DIR/arch/x86_64"
cp "$WORK_DIR/iso/arch/x86_64/airootfs.sfs" "$OUT_DIR/arch/x86_64/"
cp "$WORK_DIR/iso/arch/x86_64/airootfs.sha512" "$OUT_DIR/arch/x86_64/"

# Cleaning work dir (after build)
rm -rf "$WORK_DIR"

# Cleaning profile dir (after build)
rm -rf "$PROFILE_DIR"

echo "Build Complete!"
