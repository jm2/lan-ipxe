# Fedora/Arch package mapping for macOS

Active package arrays from the repository scripts; **A** = Arch, **F** = Fedora. This covers 271 distinct entries, including Linux-only groups, rather than silently treating every distro runtime package as an app requirement. Dynamic hardware-specific driver/microcode additions remain OS-specific.

Core parity is default. Full contains the additional heavy developer and optional gaming stack. A dependency can already be installed by core even when full makes it an explicit requirement. Project-only entries are deliberate exceptions requiring a supported project configuration. Windows GUI capability comparison remains in the [approved plan](setup-macos-workstation-plan.md).

| Linux entries | macOS disposition | Implementation/reason |
| --- | --- | --- |
| `@gnome-desktop` (F), `NetworkManager` (F), `alsa-sof-firmware` (F), `archlinux-appstream-data` (A), `bluez` (A/F), `bluez-tools` (F), `bluez-utils` (A), `chrony` (A/F), `cockpit` (A/F), `cockpit-files` (A/F), `cockpit-packagekit` (A/F), `cockpit-podman` (A/F), `cockpit-storaged` (A/F), `cronie` (A/F), `cups` (A/F), `cups-pk-helper` (A/F), `dkms` (F), `dnf5-plugin-automatic` (F), `downgrade` (A), `dracut` (A/F), `efibootmgr` (A/F), `flatpak` (F), `gnome` (A), `gnome-circle` (A), `gnome-extensions-app` (F), `gnome-extra` (A), `gnome-firmware` (A), `gnome-shell-extension-appindicator` (A/F), `gnome-shell-extension-dash-to-dock` (A/F), `gnome-shell-extension-dash-to-panel` (A), `gnome-shell-extension-desktop-icons-ng` (A), `gnome-shell-extension-freon` (F), `gnome-shell-extension-system-monitor` (F), `gnome-shell-extension-vitals` (A), `gnome-shell-extensions` (A), `gnome-tweaks` (F), `grub` (A), `grub2` (F), `gst-plugin-pipewire` (A), `gst-plugins-ugly` (A), `kernel-headers` (F), `lib32-libva-intel-driver` (A), `lib32-vulkan-asahi` (A), `lib32-vulkan-broadcom` (A), `lib32-vulkan-dzn` (A), `lib32-vulkan-freedreno` (A), `lib32-vulkan-gfxstream` (A), `lib32-vulkan-intel` (A), `lib32-vulkan-nouveau` (A), `lib32-vulkan-panfrost` (A), `lib32-vulkan-powervr` (A), `lib32-vulkan-radeon` (A), `lib32-vulkan-swrast` (A), `lib32-vulkan-virtio` (A), `libva-intel-driver` (A), `libva-intel-media-driver` (F), `libva-nvidia-driver` (A), `linux` (A), `linux-firmware` (A), `linux-headers` (A), `linux-lts` (A), `linux-lts-headers` (A), `lvm2` (A), `mesa-vulkan-drivers` (F), `mesa-vulkan-drivers.i686` (F), `mokutil` (F), `networkmanager` (A), `nvidia-open` (A), `nvidia-open-lts` (A), `nvidia-utils` (A), `opencl-mesa` (A), `pacman-contrib` (A), `pipewire` (A/F), `pipewire-alsa` (A/F), `pipewire-jack` (A), `pipewire-pulse` (A), `pipewire-pulseaudio` (F), `power-profiles-daemon` (A), `sof-firmware` (A), `system-config-printer` (A/F), `udisks2-lvm2` (F), `vulkan-intel` (A), `vulkan-loader.i686` (F), `vulkan-mesa-layers` (A), `vulkan-radeon` (A), `wireplumber` (A/F), `wpa_supplicant` (A/F), `zram-generator` (A/F) | OS-specific | Linux desktop/service/kernel/driver/package-manager integration; macOS supplies its own stack |
| `glibc-devel.i686` (F), `libgtop` (A), `libstdc++-devel.i686` (F), `libva.i686` (F), `readline-devel.i686` (F), `zlib-ng-compat-devel.i686` (F) | OS-specific | Linux multilib/System Monitor extension dependencies; no Mac multilib or GNOME extension replay |
| `antigravity` (A), `code` (A/F), `google-chrome` (A), `google-chrome-stable` (F), `vlc` (A/F) | core | Corresponding Homebrew cask; preserve existing native/Store ownership |
| `zed` (A) | core | Official signed Apple Silicon DMG and bundled CLI link; avoids Homebrew's hanging completion-generation step |
| `android-sdk-platform-tools` (A) | core | Google platform-tools archive; same SDK root/owner used by full |
| `bash-completion` (A/F) | core | Homebrew bash-completion |
| `bash-preexec` (A) | core | Homebrew bash-preexec |
| `bc` (F) | core | Homebrew bc |
| `bison` (A/F) | core | Homebrew bison |
| `ccache` (A/F) | core | Homebrew ccache |
| `cdrtools` (A), `genisoimage` (F) | core | Homebrew cdrtools |
| `cmake` (A/F) | core | Homebrew cmake |
| `colordiff` (A) | core | Homebrew colordiff |
| `curl` (A/F) | core | Homebrew curl |
| `dos2unix` (A/F) | core | Homebrew dos2unix |
| `dtc` (F) | core | Homebrew dtc |
| `erofs-utils` (A/F) | core | Homebrew erofs-utils |
| `flex` (A/F) | core | Homebrew flex |
| `gh` (F), `github-cli` (A) | core | Homebrew gh |
| `git` (A/F) | core | Homebrew git |
| `git-lfs` (F) | core | Homebrew git-lfs |
| `tar` (F) | core | Homebrew gnu-tar |
| `gnupg2` (F) | core | Homebrew gnupg |
| `go` (A), `golang` (F) | core | Homebrew go |
| `gperf` (F) | core | Homebrew gperf |
| `gstreamer1-devel` (F) | core | Homebrew gstreamer |
| `gtk4-devel` (F) | core | Homebrew gtk4 |
| `hfsutils` (A/F) | core | Homebrew hfsutils |
| `hivex` (A) | core | Homebrew hivex |
| `htop` (A) | core | Homebrew htop |
| `ImageMagick` (F) | core | Homebrew imagemagick |
| `jq` (F) | core | Homebrew jq |
| `less` (A/F) | core | Homebrew less |
| `libadwaita-devel` (F) | core | Homebrew libadwaita |
| `lz4` (F) | core | Homebrew lz4 |
| `lzop` (F) | core | Homebrew lzop |
| `mpv` (A/F) | core | Homebrew mpv |
| `nano` (A/F) | core | Homebrew nano |
| `opencode` (A) | core | Homebrew opencode |
| `openssh` (A) | core | Homebrew openssh |
| `pigz` (F) | core | Homebrew pigz |
| `pngcrush` (F) | core | Homebrew pngcrush |
| `rpm-tools` (A) | core | Homebrew rpm |
| `rsync` (A/F) | core | Homebrew rsync |
| `cargo` (F), `clippy` (F), `rust` (A/F), `rust-analyzer` (F), `rustfmt` (F) | core | Homebrew rustup; stable ARM64 toolchain/components |
| `screen` (A) | core | Homebrew screen |
| `sing-box` (F) | core | Homebrew sing-box |
| `squashfs-tools` (F) | core | Homebrew squashfs |
| `texinfo` (A/F) | core | Homebrew texinfo |
| `transmission-cli` (F) | core | Homebrew transmission-cli |
| `tree` (A/F) | core | Homebrew tree |
| `unar` (F), `unarchiver` (A) | core | Homebrew unar |
| `vim` (A/F) | core | Homebrew vim |
| `wget` (A/F) | core | Homebrew wget |
| `yt-dlp` (A) | core | Homebrew yt-dlp |
| `zip` (F) | core | Homebrew zip |
| `antigravity-cli` (A), `claude-code` (A/F), `ookla-speedtest-bin` (A), `openai-codex` (A), `powershell` (F), `powershell-bin` (A) | core | Official native CLI; owner-aware reconciliation (Ookla presence-only) |
| `balun` (F), `balun-bin` (A), `tributary` (F), `tributary-bin` (A) | core | Verified jm2 release app; preserve local source checkouts |
| `gnome-icon-theme` (A), `gnome-icon-theme-symbolic` (A) | core | adwaita-icon-theme; native desktop appearance managed separately |
| `transmission` (F), `transmission-daemon` (F), `transmission-gtk` (F), `transmission-remote-gtk` (F) | core | transmission-cli; no daemon enablement or Linux GTK service UI |
| `sit-git` (A) | core | unar handles legacy StuffIt archives; no unreviewed source build |
| `video-downloader` (A) | core | yt-dlp command; no Linux-only desktop wrapper |
| `@development-tools` (F), `base-devel` (A), `clang` (A/F), `lldb` (A/F) | core/native | Apple CLT clang/LLDB/make plus core autoconf/automake/libtool/m4/patch/gettext and build helpers; no Linux package-group expansion |
| `openssh-server` (F) | core/opt-in | Homebrew SSH clients; Apple sshd only with --with-sharing |
| `libicu` (F) | dependency | Homebrew icu4c dependency of the selected GTK/media stack |
| `gdb` (A/F) | exception | Apple LLDB; GDB requires additional Darwin debugger signing/privileges |
| `fuse-libs` (F) | exception | Do not install a macFUSE system extension or change security policy merely for Linux FUSE parity |
| `chromium` (A/F), `makemkv` (A) | exception | Homebrew cask disabled; retain installed copies (Chrome/Firefox supply browser parity) |
| `lineageos-devel` (A), `mstflint` (A), `schedtool` (F) | exception | Linux ROM build/scheduler/firmware tooling lacks an established supported Mac use case |
| `dxvk-bin` (A), `lutris` (A/F), `luxtorpeda-bin` (A) | exception | Linux/Wine gaming integration is outside the approved native Mac setup; no compatibility-prefix migration |
| `airshipper` (A), `maniadrive` (A), `openarena` (A), `tremulous-grangerhub-bin` (A), `unigine-heaven` (A) | exception | No reviewed maintained native ARM64 artifact in this manifest; no arbitrary source builds |
| `tuxracer` (A) | excluded | Inventoried Extreme Tux Racer is a Store app |
| `bugdom` (A), `bugdom2` (A), `mightymike` (A), `nanosaur` (A), `nanosaur2` (A), `ottomatic` (A) | full | Checksum-pinned Jorio app release; bundled resources only |
| `cro-mag-rally-net` (A) | full | Checksum-pinned jm2/CroMagRally fork release; provenance receipt |
| `vulkan-devel` (A), `vulkan-loader` (F), `vulkan-tools` (F), `vulkan-validation-layers` (F) | full | Homebrew Vulkan loader/headers/tools, SPIR-V tools and MoltenVK; no Linux GPU drivers or global ICD override |
| `boost` (A), `boost-devel` (F) | full | Homebrew boost |
| `dbus-devel` (F) | full | Homebrew dbus |
| `gcc` (A/F) | full | Homebrew gcc |
| `gmp` (A), `gmp-devel` (F) | full | Homebrew gmp |
| `gnutls-devel` (F) | full | Homebrew gnutls |
| `gradle` (A) | full | Homebrew gradle |
| `steam` (A/F), `steamcmd` (A) | full | Homebrew launcher/CLI; content and sign-in manual |
| `lgogdownloader` (A) | full | Homebrew lgogdownloader |
| `elfutils-libelf-devel` (F) | full | Homebrew libelf |
| `libmpc` (A), `libmpc-devel` (F) | full | Homebrew libmpc |
| `libxml2` (F) | full | Homebrew libxml2 |
| `libxslt` (F) | full | Homebrew libxslt |
| `lld` (F) | full | Homebrew lld |
| `llvm` (A/F) | full | Homebrew llvm |
| `maven` (A/F) | full | Homebrew maven |
| `mpfr` (A), `mpfr-devel` (F) | full | Homebrew mpfr |
| `ncurses-devel` (F) | full | Homebrew ncurses |
| `jdk-openjdk` (A) | full | Homebrew openjdk |
| `openssl-devel` (F), `openssl-libs` (F) | full | Homebrew openssl@3 |
| `payload-dumper-go-bin` (A) | full | Homebrew payload-dumper-go |
| `protobuf-compiler` (F) | full | Homebrew protobuf |
| `ruby` (A/F) | full | Homebrew ruby |
| `SDL-devel` (F) | full | Homebrew sdl12-compat |
| `zlib-ng-compat-devel` (F) | full | Homebrew zlib-ng |
| `maelstrom` (A) | full | Native Mac Source Ports app; disabled Homebrew cask unused |
| `ollama-cuda` (A), `ollama-vulkan` (A) | full | Native Ollama runtime; Apple acceleration, no CUDA/Vulkan backend packages or model downloads |
| `android-ndk` (A), `android-sdk-build-tools` (A), `android-sdk-cmdline-tools-latest` (A), `android-studio` (A) | full | Studio + SDK manager; latest stable platform/build-tools/NDK, no emulator images |
| `brasero` (A/F), `gparted` (A/F) | native | Apple Disk Utility and core cdrtools; no Linux block-device UI |
| `ventoy-bin` (A) | native | Apple Disk Utility plus core image tools; no Linux/Windows Ventoy installer on macOS |
| `ptyxis` (A), `rhythmbox` (F), `seahorse` (A/F) | native | Apple Music/Terminal/Keychain; Store restoration excluded |
| `abattis-cantarell-fonts` (F), `cantarell-fonts` (A), `glibc-langpack-en` (F), `google-noto-cjk-fonts` (F), `google-noto-emoji-color-fonts` (F), `google-noto-sans-fonts` (F), `google-noto-serif-fonts` (F), `noto-fonts` (A), `noto-fonts-cjk` (A), `noto-fonts-extra` (A) | native | Apple fonts and en-US/en_US preferences; no Linux desktop font/locale package replay |
| `libpulse` (A), `libva` (F), `libva-utils` (A/F), `mesa-utils` (A) | native | Apple graphics/audio APIs; Linux VA-API/PulseAudio diagnostics do not configure Mac hardware |
| `net-tools` (A) | native | Apple ifconfig/netstat/scutil; no Linux networking utility replacement |
| `sudo` (A/F) | native | Apple sudo; never replace the system privilege tool |
| `python3-protobuf` (F) | project | Install Python protobuf in the project virtual environment; full supplies protoc. Avoid global pip mutation of Homebrew Python |

Extra explicit core support: `jq`, `shellcheck`, `ripgrep`; default Bash 3.2 completion/preexec; non-Store Firefox, GIMP, Inkscape, Meld, MediaInfo, Outline Manager and Wireshark follow Windows parity. macOS source-port data paths and native distribution exceptions are documented in the [guide](macos-workstation.md). Package sources are the [Homebrew formula/cask API](https://formulae.brew.sh/) and the named upstream releases in [manifest.json](../files/macos/manifest.json), checked 8 September 2026.
