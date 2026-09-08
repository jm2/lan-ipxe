# Proposed `setup-macos-workstation.sh`

**Status: approved and implemented on 8 September 2026, with Go in core and Android option 1 (stable platform/build-tools/NDK) in full. See the [implementation guide](macos-workstation.md) for resolved sources, exceptions and validation limits. The setup has not been applied to this Mac.**

Build a new macOS-specific Bash script that reproduces the deliberate parts of this Mac's setup, follows this repository's state-reconciliation conventions, and includes sensible Windows/Fedora/Arch parity in the default core profile. Use the [inventory](macos-workstation-inventory.md) and [sanitized snapshot](macos-workstation-inventory.json) as evidence, not as files to replay wholesale.

The inventory was taken on 7–8 September 2026 against repository commit `72cbcd6977f65e240ad6b61a18a37aecb6d90b8b`. The initial support target should be **Apple Silicon, macOS 26**, matching this M1 Max machine. Design architecture detection cleanly, but do not claim Intel or older-macOS support until it is tested.

## Approved scope

The user approved the plan with these changes:

- **Core includes parity by default.** Include Homebrew CLI programs corresponding to the active Linux workstation manifests, including tools such as `wget`, even when they are not yet installed on this Mac. Omit only packages that are unavailable, redundant with an intentional macOS implementation, or problematic on macOS, and document the reason. Additional heavy toolchains/libraries may move to full as proposed below; do not omit ordinary utilities such as wget on that basis.
- **No `--with-parity` flag or separate parity tier.** Everyday developer tools and sensible non-Store desktop equivalents belong in core; additional heavy toolchains, optional applications and games belong in full.
- **Ignore all Mac App Store apps.** No `mas`, Store IDs, Store sign-in/purchase/restore workflow, or automation of the inventoried Store/mobile apps. Preserve existing Store installations without replacing them with casks. The inventory remains a historical record, not an install manifest.
- **Full adds games and optional non-Store apps.** Cro-Mag Rally must use a release from `jm2/CroMagRally`. The other Pangea ports must use Jorio's releases.
- **No separate game-data acquisition or restoration.** At the end of every full run, report the directories the user needs to populate for each selected game/engine. Preserve data included inside an approved upstream app release; do not separately download, extract, copy, or modify game data or saves.
- **Port all compatible Linux shell configuration.** Cover every setting in `files/bashrc` and `files/etc/bash.bashrc`, with macOS equivalents and explicit platform exceptions. Integrate the result into both interactive and login Bash startup.
- Preserve normal-user execution, Apple Bash 3.2 bootstrap compatibility, native Apple Silicon support, idempotence, owner-aware updates, existing user work, and read-only check/dry-run behavior.
- Sharing and power stay explicit opt-ins. Full Xcode installation is outside scope under the Store exclusion; an optional phase may select an Xcode app already supplied by the user.

**Approved size/use split:** core keeps everyday CLI/build helpers, Python/Rust/**Go**, existing GTK/GStreamer development support and primary editors/agents. Full adds Java/Maven/Gradle, Homebrew Ruby, standalone GCC/LLVM/lld, Android Studio/SDK/NDK, Ollama and additional large development libraries, as well as optional apps/games. Existing tools are never uninstalled when running core.

**Android decision:** the user selected option 1: provision the current stable platform/build-tools/NDK in full, using one SDK root/one platform-tools owner, no emulator/system-image downloads, and explicit SDK license interaction.

The requested answer checkpoint is complete; implementation is authorized. Resolved release assets, aliases and exceptions are recorded in the implementation manifests and guide.

## Comparison with the existing scripts

The comparison covers the active manifests and execution paths in [Windows](../setup-win11-workstation.ps1), [Fedora](../setup-fedora-workstation.sh), [Arch](../setup-arch-workstation.sh), shared [Bash settings](../files/bashrc), [prompt](../files/etc/bash.bashrc), [Vim settings](../files/vimrc), and [CI](../.github/workflows/lint.yml). Commented-out Windows packages are not counted as installed intent.

| Behavior | Existing implementation | macOS plan |
| --- | --- | --- |
| Execution identity | Linux runs as normal user with sudo; Windows requires elevation | Normal console user; reject running the whole script as root. Privilege only individual system/package operations. |
| Reconciliation | Linux compares content/type/mode/owner; follow-up reloads only after changes. Windows uses one WinGet inventory and exact IDs | Snapshot once; compare app bundle IDs, formula/cask ownership, typed preferences, file contents and links. Refresh only affected state after changes. |
| Updates | Fedora updates DNF/Flatpak and vendor tools; Arch full `pacman -Syu` plus AUR updates; Windows exact-ID updates, except presence-only Speedtest | Scope Homebrew updates to the selected manifest plus required dependencies; preserve native app update channels. Never run blanket cleanup or remove extras. |
| Native tool installation | Fedora resolves native verified artifacts; Arch official/AUR packages; Windows WinGet | Native ARM64 Homebrew/official artifacts; version, checksum/signature, bundle-ID and architecture validation where appropriate. |
| Error handling | Windows continues after individual installer errors and summarizes failures; Linux uses fatal prerequisite/helper failures | Fatal preflight/core consistency errors; collect independent app failures and manual actions so one unavailable optional app does not block everything. |
| Configuration payloads | `files/` resolved relative to script | Same convention, with macOS-specific payloads. Existing `files/vimrc` is portable and belongs in core. |
| Linux shell settings | Linux SDK/JDK paths, `nproc`, GNU color commands, `ssh -Y` alias | New macOS PATH/prompt fragments. Do not copy `files/bashrc` or the global Linux prompt verbatim. Use `getconf`/`sysctl` when parallelism is needed and BSD-compatible commands. |
| Services | Linux systemd/Cockpit/sshd/GDM; Windows OpenSSH and optional Hyper-V | Built-in macOS launchd/Sharing; explicit opt-ins for network services. No systemd/cron emulation of the Linux workstation. |
| Platform maintenance | Linux drivers, bootloader, initramfs, zram, sysctl, package repos, automatic reboot policy | Leave to macOS. Record/apply selected supported update preferences; no forced OS upgrade, reboot, or fabricated Linux equivalents. |

Application/tool parity, with **W/F/A** denoting active Windows/Fedora/Arch intent:

| Capability | Repo intent | This Mac | Proposed disposition |
| --- | --- | --- | --- |
| Chrome | W/F/A; Chromium also F/A; Firefox W | Chrome installed/default; Safari supplied by OS | Chrome core; Firefox/Chromium core where a supported non-conflicting macOS channel exists. Document any unavailable/deprecated channel instead of silently substituting it. |
| VS Code | W/F/A; old VSCodium retired | Installed; ten extensions; no `code` on login PATH | Core; expose CLI and merge observed editor settings. No migration needed for absent VSCodium. |
| Antigravity desktop/CLI | W/F/A; legacy 1.x replaced | Desktop 2.12.2; two `agy` copies | Core; detect v2 identity and reconcile one public CLI. Do not install the legacy IDE. |
| Claude Code / Codex CLI | W/F/A | Native standalone installs | Core; retain native CLI owners and desktop Claude. Preserve the existing Codex desktop identity. |
| OpenCode / Zed | W/F/A | Absent | Core: Homebrew OpenCode and the Zed cask. |
| Git / GitHub CLI | W/F/A; GitHub Desktop W; Git LFS F | Apple Git and Homebrew `gh`; Desktop/LFS absent | Core Homebrew Git, Git LFS and gh. GitHub Desktop is an optional full-profile GUI. No identity/auth provisioning. |
| Python | Latest stable Python resolved on W; Python tooling/dependencies F/A | CLT and Brew Python coexist | Core explicitly requests current stable Homebrew Python and establishes deliberate interactive PATH precedence; preserve Apple tool paths. |
| Rust | W rustup; F/A distro toolchain | Brew rustup, stable ARM64 compiler | Core rustup with stable native target and rustfmt/clippy/rust-analyzer. No duplicate Homebrew rust compiler owner. |
| C/C++ tools | W CMake/LLVM/Ninja/Visual Studio; extensive F/A build sets | CLT/Xcode present; standalone CMake/Ninja absent | CLT/Apple clang/LLDB and CMake/Ninja/ccache in core. Additional GCC/LLVM/lld and large development libraries in full; preserve Apple SDK integration. |
| Go | W/F/A | No standalone command | Core Homebrew Go, explicitly requested by the user. |
| Java/build tools | JDK/Gradle/Maven A; Maven F | Not found as workstation installs | Full: current stable OpenJDK, Maven and Gradle, with project-specific JDK overrides. |
| Ruby and shell utilities | F/A Ruby, completion, colordiff, dos2unix, htop, tree, rsync, screen, vim, wget, etc. | Apple command set plus tmux/tree/gh | Everyday utilities in core, including wget/rsync/Vim and shell settings. Extra Homebrew Ruby in full; preserve the system Ruby. |
| GTK/GStreamer development | F/A libraries; Tributary/Balun packages | Five requested GTK/GStreamer/icon/pkgconf formulae; self-contained apps | Core observed developer library set plus required supported development libraries. Let Homebrew resolve transitive dependencies. |
| Android Studio / SDK / NDK | W/F/A, differing architecture sets; LineageOS tools A | Absent | Full: Studio and SDK/NDK development stack, with the latest stable platform/build-tools/NDK. |
| PowerShell | W/F/A | Official package 7.6.5 | Core official native package and public pwsh command, preserving existing ownership. |
| Terminal / OpenSSH | Windows Terminal and SSH server W; shell/SSH services F/A | Terminal Clear Dark; Bash; SSH enabled record | Core shell/Terminal and supported OpenSSH client tools; optional sharing uses Apple system sshd, not a second Homebrew daemon. |
| Tributary / Balun | Tributary W/F/A; Balun F/A | Both installed, local source checkouts | Core approved release bundles. Do not build from or modify existing local checkouts. |
| VLC / mpv | W/F/A (mpv.net on W); ffmpeg in dependencies here | No VLC/mpv app/command; ffmpeg Brew dependency | Core VLC and mpv; ffmpeg may be satisfied by their Homebrew dependency closure. |
| HDHomeRun / Plex | W | HDHomeRun and iOS Channels installed; Plex absent | Ignore installed Store HDHomeRun/Channels. Plex is optional full-profile non-Store software. |
| MakeMKV / MediaInfo | W; MakeMKV A | Absent | Core supported non-Store editions, subject to current package/architecture validation. |
| GIMP / Inkscape / Meld | W | Affinity Photo, BBEdit, Hex Fiend present | Core supported non-Store equivalents; leave inventoried Store Affinity/BBEdit/Hex Fiend outside management. |
| Tailscale / Outline | W; Outline Client/Manager F | App Store Tailscale and Outline Client; no Manager | Ignore inventoried Store clients and do not switch their variants. Outline Manager can use a supported non-Store core installer. |
| Ookla Speedtest | W GUI+presence-only CLI; F pinned CLI; A AUR CLI | Store GUI only | Ignore the Store GUI. Core official Ookla CLI, preserving the repository’s intentional presence-only/version policy. |
| Steam / GOG / Battle.net | Steam W/F/A; GOG Galaxy W; A lgogdownloader; Battle.net commented out W | All three clients; Blizzard games; Steam AoE2DE content | Full profile launchers. No content downloads; print manual content/data actions. Preserve already installed clients. |
| Pangea/Jorio games | Bugdom/2, Cro-Mag Rally, Nanosaur/2, Otto Matic, Mighty Mike F/A; Maelstrom A | Those plus Billy Frontier installed | Full: jm2/CroMagRally fork release; Jorio releases for the other seven inventoried Pangea ports. No separate data acquisition. |
| Other games/engines | W SuperTux/Kart/Extreme Tux Racer/Heaven; A OpenArena, Tremulous, tuxracer, Maniadrive, Veloren launcher and others | Store Extreme Tux Racer, numerous purchased games, ETLegacy, Quake/Doom/Prey/UT ports | Full: supported non-Store open-source games and source ports. Report per-engine data directories; never download supplemental data or saves. |
| Archives / disk / transfer tools | W 7-Zip, WinDirStat, WinSCP, PuTTY, Rufus, Ventoy; F/A unar and Linux disk tools | Keka, GrandPerspective, Hex Fiend, native SSH/scp/rsync/Disk Utility | Core Homebrew CLI equivalents such as unar, compression and image utilities; Apple Disk Utility/SSH where appropriate. Ignore Store GUI apps. |
| Wireshark / X11 | Wireshark and Xming W; Linux display and media stacks F/A | Neither Wireshark nor XQuartz found | Core Wireshark if supported; omit XQuartz/global ssh -Y unless an actual X11 dependency requires them. Record this platform exception. |
| Virtualization / containers | Optional Hyper-V and WSL W; Cockpit/Podman integration F/A | No Docker/Podman/UTM/Parallels app found | Separate future choice. No VM/container app or VM image was observed; do not translate Hyper-V/WSL/Cockpit into an arbitrary Mac product. |
| Cloud/personal applications | Google Drive/iTunes W; native Linux desktop apps/groups F/A | Apple Music/TV/iCloud plus Store productivity, mobile apps and utilities | Ignore all inventoried Store/mobile apps. Google Drive and other optional non-Store personal apps may belong in full; account sync stays manual. |
| Linux-only packages | Kernels, NVIDIA/Vulkan drivers, r8152 DKMS, GRUB/dracut, zram, inotify, GNOME/GDM, PipeWire, multilib, firmware, service stack | Managed by macOS/native hardware stack | Exclude. Generic libraries needed to build a project are resolved separately by that project's supported macOS dependencies. |
| Windows-only tooling | WingetCreate, Windows Terminal, WSL, Hyper-V, Rufus, driver tools | Not applicable | Exclude; do not equate inventory absence with a missing Mac requirement. |

This is capability parity, not an instruction to install the union of hundreds of distro packages. Linux package groups expand differently, and many package entries implement the operating system itself.

## Proposed install manifests

### Core: default workstation and cross-platform parity

The final manifest must map every active Fedora/Arch CLI or build-tool entry to a Homebrew equivalent, a native macOS provision, a full-profile heavy toolchain/gaming tool, or a documented exception. Homebrew formula availability alone is insufficient: validate supported macOS/architecture, disabled/deprecated state and conflicts before enabling a package. Do not copy distro runtime/kernel/desktop packages wholesale.

| Group | Core package/tool targets |
| --- | --- |
| Shell and general CLI | `bash-completion` for Apple Bash 3.2, `bash-preexec`, `bc`, `colordiff`, `dos2unix`, `htop`, `less`, `nano`, `screen`, `tmux`, `tree`, `vim` |
| Downloads, version control, remote clients | `curl`, `wget`, `rsync`, `git`, `git-lfs`, `gh`, `openssh`, `gnupg` |
| Languages and developer agents | current stable Homebrew Python, `go`, `rustup` and native stable Rust/components, `opencode`, native Codex/Claude Code/Antigravity CLI, official PowerShell. Node may arrive as an agent/editor dependency; do not install duplicate owners. |
| Build tools | Apple CLT/clang/LLDB, `bison`, `flex`, `gperf`, `cmake`, `ninja`, `ccache`, `pkgconf`, `texinfo`. Additional compilers/linkers/code-generation stacks move to full. |
| Archives, images and media CLI | `cdrtools`, `dtc`, `erofs-utils`, `hfsutils`, `hivex`, `rpm`, `gnu-tar`, `zip`, `unar`, `lz4`, `lzop`, `pigz`, `squashfs`, `imagemagick`, `pngcrush`, `mpv`, `yt-dlp`, `transmission-cli` |
| Service-capable CLI tools | `sing-box` in core without configuring a tunnel or starting a daemon. Ollama moves to full; no model downloads or automatic service enablement. |
| Development libraries | Keep the observed `gtk4`, `libadwaita`, `gstreamer`, `adwaita-icon-theme` development environment in core. It has a substantial dependency closure, but is already part of this Mac’s setup. Add extra build libraries in full; dependencies can satisfy shared libraries in either profile. Do not promote all 124 observed formulae into separate requirements. |
| Repository/bootstrap support | `jq`, `shellcheck`, `ripgrep`; these are explicit implementation/tooling additions where not already in a Linux manifest |
| Android device utility | Small `adb`/`fastboot` platform-tools functionality can remain in core; the Studio/SDK/NDK build stack is full. Ensure core and full share one platform-tools owner instead of installing competing copies. `payload-dumper-go` belongs with the full Android build/image-tool set. |
| Non-Store desktop parity | Chrome, VS Code, Antigravity 2, Claude, Zed, Tributary, Balun, XRG, VLC and supported counterparts for Firefox/Chromium, GIMP, Inkscape, Meld, MakeMKV, MediaInfo, Outline Manager and Wireshark |

62 CLI/build-tool formula records were fetched from the [official Homebrew formula API](https://formulae.brew.sh/formula/) during this revision; each had Apple Silicon or architecture-independent bottles and none was disabled/deprecated. This check covered the main CLI rows, not every GUI/library/candidate entry. The implementation must still validate each final package and its postconditions. The current Python alias resolves to `python@3.14`; `sdl2` maps to `sdl2-compat`; Fedora/Arch package spellings are not necessarily Homebrew names.

Keep Apple `/bin/bash` as the login shell. Use [Bash-3-compatible completion](https://formulae.brew.sh/formula/bash-completion), not completion v2. Bootstrap syntax remains Bash 3.2-compatible even if a dependency supplies newer Bash. Include the portable `files/vimrc` in core.

Homebrew language tools become the intended interactive commands where selected, while Apple tools remain available at their own paths. Do not replace `/usr/bin`, globally shadow Apple SDK clang with an incompatible compiler, or add every keg-only `gnubin` directory to PATH. When full is selected, install its language toolchains and select Java through discovered macOS/Homebrew paths, with Android/project-specific JDK selection isolated as needed. Core shell configuration detects pre-existing JDK/SDK installations without installing the full toolchains.

### Full: additional toolchains, optional non-Store apps and games

Full contains all of core plus:

| Group | Full-profile additions and rationale |
| --- | --- |
| Java ecosystem | OpenJDK, Maven, Gradle: additional compiler/runtime and build stack rather than everyday shell utilities |
| Additional language runtime | Homebrew Ruby in full; Python, Rust and Go remain core |
| Additional C/C++ toolchains | GCC, LLVM/lld and related tooling: useful for parity, but substantially overlap Apple CLT for ordinary native development |
| Extra development libraries | Boost, explicit SDL development support, protobuf/code generation and other large project-specific build libraries. Libraries already required by core packages remain satisfied through core dependencies. |
| Android | Android Studio, SDK command-line tools, selected platforms/build-tools/NDK and payload extraction tools. No emulator/system-image downloads. |
| Local model runtime | Native Ollama CLI/runtime; no model downloads or server startup |
| Optional apps and games | GitHub Desktop, Plex, Google Drive, game launchers and supported open-source games/source ports |

Full uses the same owner-aware installation rules as core; selecting core on an already full-equipped Mac never removes tools. Xcode itself remains separately handled as previously approved, not moved into full just because of its size. User-supplied Xcode can be selected with the dedicated option; Store installation is excluded. It does not reintroduce Store apps or mobile wrappers. Existing Store apps are untouched; do not install a duplicate edition over them.

Pangea game sources are fixed by user instruction:

| Game | Release owner/repository |
| --- | --- |
| Cro-Mag Rally | `jm2/CroMagRally` — the fork release, never Jorio's upstream release as fallback |
| Billy Frontier | `jorio/BillyFrontier` |
| Bugdom | `jorio/Bugdom` |
| Bugdom 2 | `jorio/Bugdom2` |
| Mighty Mike | `jorio/MightyMike` |
| Nanosaur | `jorio/Nanosaur` |
| Nanosaur 2 | `jorio/Nanosaur2` |
| Otto Matic | `jorio/OttoMatic` |

Resolve stable macOS release assets from the named repositories at implementation/runtime as appropriate. Validate asset identity, architecture and available checksums/signatures. Record repository, tag and asset digest in a managed receipt, especially for Cro-Mag Rally: the fork may share the upstream bundle ID/version, so those alone do not prove the correct variant. An unresolved fork asset is a reported failure/deferred item, never permission to substitute upstream or build from the local checkout.

Other full candidates include Maelstrom, SuperTux/SuperTuxKart, Extreme Tux Racer, OpenArena and the observed ETLegacy, Quake, Doom, Prey and Unreal engine ports where supported release artifacts exist. Jorio ownership applies to the Pangea family; unrelated engines use their own maintained upstreams. Steam, GOG and Battle.net belong in full. Game-specific CLI utilities such as `lgogdownloader` and SteamCMD also belong in full if supported, with no automatic download invocation.

### Game-data report at the end of full

Do not download or restore supplemental game assets, demo/shareware packs, purchased content, saves or user settings. Do not launch games merely to cause them to create directories. Preserve upstream app-bundled resources as delivered.

Every full run, including an already-converged rerun, ends with a table containing:

- Game/engine and installed app/version.
- Exact effective destination directory/directories, expanded for the current user, with required relative subfolders.
- Required filenames or folder layout, based on the selected release's documented search paths.
- A lightweight `present`, `missing`, `not required (bundled)`, or `unverified` status; never claim playability from a filename check.
- A short note for manual placement or launcher-managed content.

Examples to verify against selected releases include Quake III's `baseq3`/`missionpack`, Doom 3's `base`, Quake II's `baseq2`, ETLegacy's `etmain`, Prey's `base`, and the relevant UT/UT2004 content folders. Existing support folders from the inventory are clues, not proof that a new engine build searches those exact locations. Resolve actual paths before emitting instructions; account for app-local versus user-support directories and preserve existing symlinks/data.

Pangea releases that already contain everything get `not required (bundled)`. Missing user-supplied game data is informational and does not make an otherwise successful setup fail; a missing/failed selected game engine still affects the setup result. Print the data checklist even if another optional installer fails.

### Documented macOS exceptions

- Linux kernels, drivers, initramfs/GRUB, zram/inotify, GNOME/GDM, PipeWire, package managers and service integration are supplied by the operating system or inapplicable.
- Use CLT/Apple LLDB for native debugging. [Homebrew GDB](https://formulae.brew.sh/formula/gdb) requires additional code-signing/privileges on Darwin, so it is excluded from automatic core setup rather than installed with an unfulfilled debugger configuration.
- Install Homebrew OpenSSH clients if selected, but optional Remote Login uses Apple's service and does not start a competing daemon.
- Keep native Apple trust/OS tooling; no Linux CA-bundle symlinks, `sudo` replacement or generic service-enablement loop.
- XQuartz/global `ssh -Y`, VM/container products, firmware flashing and Linux-only Android-ROM build machinery need a real supported Mac use case rather than a name-based substitute.
- Ignore all inventoried Store apps, including Tailscale/Outline Store variants. Do not silently migrate to standalone/cask editions to work around this exclusion. Xcode is user-supplied if its optional selection phase is requested.
- Unsupported/deprecated packages and unexpected conflicts must be listed with reasons. Package availability/size alone does not justify silently moving ordinary Linux CLI parity out of core.

## Complete Fedora/Arch shell configuration port

The repository currently installs `files/bashrc` and `files/etc/bash.bashrc` (as Fedora's profile.d prompt); there is **no separate Linux bash_profile payload**. The Mac implementation must add the missing login-to-interactive startup integration while preserving Apple's `/etc/profile`, `/etc/bashrc`, Terminal session handling, and existing user profile content.

| Linux setting/behavior | macOS equivalent |
| --- | --- |
| Source system Bash defaults | Preserve Apple system initialization and existing hooks; avoid recursive/double sourcing. Add a managed, guarded `.bash_profile` → `.bashrc` integration for interactive login shells. |
| Interactive guard | No prompt output, aliases, completion side effects or title escapes in non-interactive shells, including SSH/scp/script contexts. |
| `checkwinsize`, `histappend` | Port both Bash shopt settings. Preserve macOS Terminal history/session mechanisms. |
| Title via `PROMPT_COMMAND` | Port user/host/current-directory titles for supported terminals; keep Apple `update_terminal_cwd` and existing scalar/array hooks. Deduplicate on repeated sourcing; preserve the previous command exit status. |
| Color detection and prompt | Preserve tput/TERM detection, colored username/host and working directory, root distinction, failure marker, non-color fallback, and escaped nonprinting sequences. No Bash-4-only syntax in the bootstrap/profile fragments. |
| `PS2`, `PS3`, `PS4` | Port the `> `, `> ` and `+ ` values. |
| `~/bin`, `~/.local/bin`, `~/.cargo/bin`, `~/go/bin` | Preserve intent with deduplicated PATH entries; respect custom `CARGO_HOME`/Go locations if supplied. Correctly order native Homebrew, rustup and existing user CLIs. |
| `ANDROID_HOME`, `ANDROID_SDK_ROOT` | Set consistently to a verified Mac SDK root only when available; respect a valid user/project override. Never emit the Linux `/opt/android-sdk` path or a nonexistent location. |
| `ANDROID_NDK_HOME` | Set to the selected installed NDK, respecting a valid override and project-specific version. No Linux `/opt/android-ndk` assumption. |
| SDK command-line PATH | Discover the actual tools/platform-tools locations. Avoid a second SDK tree and duplicate adb/fastboot owners. |
| `JAVA_HOME` | Resolve an installed compatible JDK using macOS discovery/Homebrew metadata; respect valid overrides. No `/usr/lib/jvm/default` and no empty/error output when core has no JDK. |
| `MAKEFLAGS=--jobs=$(nproc)` | Use detected logical CPU count from macOS and a `-jN` spelling supported by the chosen make. Set the default when absent; preserve user flags/jobserver settings and avoid multiplying job limits when profiles are sourced repeatedly. |
| `EDITOR=vi` | Preserve `vi` as the default editor, while keeping an explicit user override. Core Vim supplies the desired editor functionality. |
| `USE_CCACHE=1` | Port the export; ccache belongs in core. Do not force compiler-wrapper PATH changes absent from the Linux payload. |
| `diff=colordiff -u` | Port the alias when colordiff is available. |
| `ssh=ssh -Y` | Port conditionally when a working local X11/XQuartz environment is detected; otherwise leave ssh unchanged and document why. Do not install XQuartz merely to make this alias effective. |
| Colored `ls` and `dir` | Map to BSD ls flags (`-G`, plus column/escape behavior for dir) or compatible already-installed GNU tools; never apply GNU-only flags to Apple ls. |
| Colored `grep` | Use a verified supported `--color=auto` implementation, leaving non-color fallback functional. |
| `dircolors` and `~/.dir_colors` | Honor user rules when compatible dircolors/gdircolors is installed; otherwise use native terminal-aware ls coloring. Do not parse GNU LS_COLORS as if it were BSD LSCOLORS. |
| `dmesg --color` | Omit the Linux-only color flag; retain the native command. |
| Bash completion and preexec | Use the Homebrew Bash-3-compatible paths and preserve other hooks. Guard for missing packages and avoid repeated loading. |
| Arch pkgfile/pacman hooks | Omit distro-only hooks; commented-out fortune/pacman options are not active settings to invent on Mac. |
| Temporary helper variables/functions | Clean up port-owned helpers without unsetting user variables or existing prompt functions. |

The portable environment detection should work in either profile and recognize a full toolchain that was already installed independently. Bash-specific prompt/shopt logic must not be sourced as Zsh; Zsh login integration only receives compatible environment/PATH setup.

Add behavior tests covering login/non-login interactive Bash, non-interactive SSH-like invocation, repeated sourcing, existing Apple prompt hooks, no JDK/SDK, installed/custom JDK/SDK, user-provided MAKEFLAGS, correct failed-command prompt status, and paths containing spaces. This is full behavior coverage of the two active Linux payloads, not a verbatim file copy.

## Script structure and execution contract

Proposed interface:

```text
setup-macos-workstation.sh [--profile core|full]
    [--with-xcode] [--with-sharing] [--with-power-settings]
    [--dry-run | --check] [--no-upgrade] [--help]
```

`--dry-run` and `--check` must work before Homebrew or CLT exists. Neither requests sudo, launches installers, writes defaults, starts services, updates package metadata, or creates a new tool environment. Missing prerequisites are reported as planned/deferred work. Logs for normal installation go to a user-owned state directory; dry-run output can be redirected by the caller.

Implementation phases:

1. **Preflight:** parse all arguments before side effects; confirm Darwin, supported OS/architecture, intended normal user and home, script-relative payloads, console-session availability, prerequisites, free space, and selected profile. Reject ambiguous translated/dual-Homebrew situations rather than building an x86 toolchain accidentally. No hard-coded username or machine UUID.
2. **Read current state and resolve work:** formula/cask JSON, app bundle identities, official-package receipts, CLI paths, typed defaults, enabled service records. Produce action records containing the reason, desired state and owner. Treat missing, installed, mismatched and unknown distinctly.
3. **Bootstrap prerequisites:** use Apple's CLT flow, with clear rerun instructions if UI completion is needed; install Homebrew at the native default prefix from the official source; run Homebrew as the normal user. Stage downloads in a temporary directory with cleanup traps. Never solve permissions by recursively changing ownership of broad system trees.
4. **Packages and languages:** update metadata once in a mutating run, install/upgrade the selected owned formulae, configure rustup components only when missing, and ensure language PATH precedence is explicit. Formula snapshots do not pin all transitive libraries to today's versions.
5. **Apps and CLIs:** reconcile each owner independently. An existing non-cask app with the expected identity is satisfied without a forced cask adoption. Handle self-updating casks according to their declared behavior; do not use greedy reinstalling to overwrite a running app. Install vendor CLI links atomically and detect command collisions. Preserve official package ownership for PowerShell.
6. **Scope exclusions:** filter out inventoried Mac App Store/mobile apps. Never install mas, request Store login, enumerate purchases, replace an existing Store app with a cask, or fail because an excluded Store app is absent. Optional Xcode selection requires an already installed user-supplied app.
7. **Full-profile games:** install approved launchers and redistributable engine/app releases; validate architecture and identity. Do not acquire supplemental data/saves; always produce the per-game directory report described above. Install Rosetta only if selected Intel software needs it and only through Apple's supported process; the current Mac already has it. Battle.net's installer can be interactive.
8. **Shell/editor payloads:** use tagged managed blocks, preserve unmanaged content, back up prior values/content on real changes, and use atomic writes with correct ownership/modes. Ensure both Bash and Zsh login profiles can find the native Homebrew and chosen CLIs without duplicating PATH entries. Expose `code` via the installed app. Merge VS Code JSON settings while preserving JSON-with-comments content, unrelated settings and existing extensions. No account-token copying.
9. **Desktop preferences:** apply an allowlist of typed keys and import only the named Terminal profile. Build Dock items from installed bundle identities/paths, without copying archived bookmarks, GUIDs or recent-app data. Reconcile only the profile's managed Dock entries while preserving unrelated user additions; an exact whole-Dock reset would require a separately approved policy. Restart affected UI components at most once and only if changed; report preference changes that need logout instead of logging the user out.
10. **Opt-in system settings:** separately implement approved sharing and power targets. Check supported tools/privileges and actual effective state. No automatic guest SMB access, firewall disabling, broad SSH access, or security-policy changes. Preserve FileVault, SIP and Gatekeeper. Do not treat TCC database writes as provisioning. Preserve current automatic-update policy without scheduling a surprise reboot.
11. **Verification and summary:** verify installed identities/architectures, public command paths, typed values, links and requested services; report changed/current/failed/manual/deferred outcomes. Store only redacted operational evidence. Do not claim launchability of every game based on a bundle check.

Proposed exit statuses: **0** when the selected automated work is satisfied (missing user-supplied game data is an informational checklist item); **1** for failures; **2** for drift or required manual/deferred actions. A valid dry-run exits 0 after displaying its plan. Never print an unconditional “done” while selected required applications remain unresolved.

Homebrew's [official installation guidance](https://docs.brew.sh/Installation) specifies the native prefix and normal-user package operations. A Brewfile is a viable future manifest alternative, but [Homebrew Bundle](https://docs.brew.sh/Brew-Bundle-and-Brewfile) upgrades by default and supports destructive cleanup; this proposal uses explicit reconciliation and does not run cleanup. A Brewfile would not solve existing app ownership or custom settings on its own.

## Platform choices retained from the approved plan

| Item | Target |
| --- | --- |
| Xcode | With `--with-xcode`, select an existing user-supplied Xcode app and report any required first-launch/license completion. Never install it through the Store. Otherwise preserve CLT selection. |
| Sharing | Explicit opt-in for SSH/Screen Sharing with the intended user's access policy. SMB paths/access rules must be specified before any SMB automation; no reproduction of guest-enabled Public sharing. |
| Power | Optional M1 Max laptop power profile; validate supported hardware/settings before applying measured sleep/display/wake values. |
| Intel apps | Prefer native releases; Rosetta only for selected Intel software through Apple's supported flow. No unrelated runtime/game downloads. |
| Speedtest CLI | Official Ookla CLI, not the unrelated Python speedtest-cli. Preserve the repo's deliberate version/presence-only policy after resolving the Mac artifact and checksum. |
| Local app bundles | Approved Balun/Tributary releases; handle per-app signing/first-launch limitations without global Gatekeeper bypass. Existing checkouts are never modified. |
| Browser extensions | User sync/reviewed installation; do not clone profiles, Secure Preferences, credentials or extension state databases. Store browser-extension apps are excluded. |
| Existing Codex desktop | Preserve the installed `com.openai.codex` identity despite the ChatGPT.app filename. A fresh install requires a verified matching distribution; otherwise report the desktop step separately while completing CLI provisioning. |

## Planned repository changes after approval

- Add `setup-macos-workstation.sh`, written for Apple Bash 3.2 and BSD utilities. Keep `main` guarded so helpers can be sourced by mocked tests without running setup.
- Add only reviewed payloads under `files/macos/`: managed shell fragments, Clear Dark Terminal profile, editor settings/extension manifest if separating those improves readability, and a defaults/Dock allowlist. No whole preference-directory backup or machine UUID data in the repository.
- Reuse `files/vimrc` in core. Do not change shared Linux payload semantics as a side effect.
- Add focused behavior tests for macOS setup and a macOS CI job. Leave existing Linux and Windows behavior intact.
- Document profiles, rerun/update behavior, ownership rules, required manual actions, supported OS/architecture, and exit statuses in `README.md`.

The inventory files remain historical evidence. The revised plan governs implementation: no Store restoration and no separate parity tier. Resolve exact non-Store sources, package aliases and game data search paths into reviewed manifests/report records. The profile split is approved with Go in core. Android option 1 is approved and implemented.

## Validation plan

1. **Bootstrap compatibility:** `/bin/bash -n` and ShellCheck; execute argument parsing/help/dry-run/check with Apple Bash 3.2 and a minimal PATH. Avoid associative arrays, `mapfile`, GNU `stat`, `install -D`, and assumptions about GNU `readlink`, `sed`, `sort` or `date`. Existing `tests/lint-bash.sh` itself uses newer Bash, so its Ubuntu job should remain; the Mac job needs a separate compatible entry point.
2. **Meaningful mocked behavior:** absent CLT/Brew; default/explicit profiles; no writes/network/sudo in check/dry-run; an existing manually installed app; a conflicting bundle ID; already-current packages; Store exclusions even when cask alternatives exist; correct jm2-versus-Jorio game provenance; no supplemental game-data transfers; accurate per-game directory reporting; missing data remaining informational; one installer failure followed by successful independent installs; changed-only preference writes; PATH/editor merges preserving unmanaged content; CLI collisions; architecture selection; privilege failure; and cleanup/error propagation. These are externally observable contracts, not tests mirroring function bodies.
3. **Idempotence:** run the same mocked installed-state fixtures twice and assert the second pass does no configuration writes, duplicate PATH/Dock insertions, installer reruns or unnecessary UI/service restarts. Package update checks are an intentional exception on normal runs. `--no-upgrade` must not accidentally trigger updates through a helper or owner migration.
4. **Native smoke verification:** on a disposable Apple Silicon/macOS 26 environment, validate the approved core bootstrap and then rerun. A hosted CI Mac with preinstalled tools does not prove a clean-machine bootstrap. Test full-profile engine/data-report outcomes separately; do not download game data or authenticate personal accounts in CI.
5. **Current Mac preview:** once code exists, run only `--check`/`--dry-run` here and review the concrete differences before a mutating run. Test Xcode/sharing/power behavior only in their selected phases, with clear postconditions and no forced reboot or logout.

Acceptance means: a reviewed manifest maps Linux CLI parity and accounts for every selected non-Store app or documented exception; the core works from a clean supported Mac; a rerun preserves unrelated user choices; optional scope is explicit; missing manual steps remain visible; and the existing Windows/Fedora/Arch checks still pass. Approval of this plan starts implementation—it does not itself run the setup on this Mac.
