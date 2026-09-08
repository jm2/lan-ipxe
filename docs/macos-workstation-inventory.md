# macOS workstation inventory — 7–8 September 2026

Read-only inventory supporting [the setup plan](setup-macos-workstation-plan.md). No installer, package update, preference write, or service change was performed. The companion [JSON snapshot](macos-workstation-inventory.json) contains the application identities, formula versions, selected settings, and extension inventory.

## Scope and confidence

The machine is an Apple M1 Max MacBook Pro (`MacBookPro18,2`), 64 GiB RAM, running macOS **26.6.2 (25G83)**. The login shell is **`/bin/bash`**, Apple Bash 3.2.57. Package history records the macOS update, Command Line Tools, Xcode, Rosetta, PowerShell, and many apps on **5 September**; several App Store upgrades were installed on **7 September**. The history also contains older image records, so it is not a clean installation timeline.

The bundle scan found **77 top-level installed apps in `/Applications`, plus Safari**, and **17 nested game/launcher/helper bundles**. That is **94 non-OS bundle records**, comprising **38 Mac App Store receipt-bearing apps, 12 iOS/iPadOS wrappers, and 44 direct/local/nested bundles**. The last number includes launcher helpers and is not a count of independently chosen apps. Another **65 bundles under `/System/Applications`** were recorded, giving **160 scanned records including Safari**. Standard application locations plus Desktop and Downloads were scanned; source checkout build products, embedded app internals, other users, external volumes, VM contents, and project dependency trees are outside that count.

Homebrew contains **124 formulae, 9 marked explicitly requested, 0 casks, and 0 taps**. It has no listed services or Homebrew launch-job files. Absence of a cask receipt does not prove which direct installer was used. App Store receipts establish the installed channel, not whether the app can still be downloaded or purchased today. iOS wrappers are identified separately because their restore behavior differs.

There is no pre-customization baseline. Values below are observed settings, not proof that every value differs from a factory default. Cached window positions, recent documents, cloud account data, credentials, private keys, and browser history are deliberately excluded. CLI package metadata, bundle plists, selected preference plists, launch configuration, installer receipts/history, extension manifests, and local project metadata were inspected. The GUI inspection failed, and administrator-only sharing/login-item getters could not complete without a password. Direct launch/registration evidence is labeled accordingly.

## Developer tools and local software

| Item | Observed state | Setup implication |
| --- | --- | --- |
| Homebrew | `/opt/homebrew`; `/etc/paths.d/homebrew` | Preserve native Apple Silicon prefix; do not install a second Intel tree. |
| Explicit formulae | `adwaita-icon-theme`, `gh`, `gstreamer`, `gtk4`, `libadwaita`, `pkgconf`, `rustup`, `tmux`, `tree` | These nine are the reproducible intent; retain the dependency list as inventory, not 124 hand-maintained requirements. |
| Rust | Homebrew rustup 1.29.1; stable `aarch64-apple-darwin`; rustc 1.98.1; only native target observed | Use rustup for compiler/components. No user `cargo install` receipt or `~/.cargo/bin` found. |
| Python | Apple/CLT Python and Homebrew Python 3.14.7 coexist; current login PATH resolves `python3` to `/usr/bin/python3` | Make Python selection deliberate. Homebrew Python currently arrives as a dependency. |
| Python packages | Apple environment: altgraph 0.17.2, future 0.18.2, macholib 1.15.2, pip 21.2.4, setuptools 58.0.4, six 1.15.0, wheel 0.37.0. Brew environment: pip 26.2.1, pycairo 1.29.1, PyGObject 3.58.0, wheel 0.47.0 | No separately installed user Python application identified; avoid replaying system packages with pip. |
| Xcode | App Store Xcode 26.6 and CLT 26.6 installed; active developer directory is `/Library/Developer/CommandLineTools` | `xcodebuild -version` currently fails because CLT is selected. Full Xcode setup and selection should be an explicit plan choice. |
| PowerShell | 7.6.5 package; `/usr/local/bin/pwsh` points into `/usr/local/microsoft/powershell/7`; added to `/etc/shells` | Preserve official package ownership and existing command. |
| Codex CLI | Standalone 0.153.4 under `~/.codex/packages/standalone`; `~/.local/bin/codex` and code-mode-host links | Do not add a competing npm or cask installation over it. |
| Claude Code | Native 2.1.261 under `~/.local/share/claude/versions`; `~/.local/bin/claude` | Preserve native updater ownership. Push notifications enabled in `~/.claude/settings.json`. |
| Antigravity CLI | ARM64 `agy` binaries in both `~/.local/bin` and `~/.gemini/bin`; current shell resolves the former | Establish one intended public command; record the other copy without deleting it based on filename alone. |
| VS Code | 1.136.1, ten extensions; `code` absent from current login PATH | Reconcile CLI exposure independently from app presence. |
| Missing standalone tools | No workstation-level `cmake`, `ninja`, `go`, `node`, `npm`, `opencode`, `zed`, or Ookla `speedtest` found in audited install/command locations | Repo parity additions require a deliberate manifest, separate from the snapshot. Tool copies embedded in editors do not supply workstation commands. |
| Shell profiles | `.bash_profile`: `~/.local/bin`, rustup PATH. `.zprofile`: Homebrew `shellenv zsh`, `~/.local/bin` | Preserve Bash; normalize a managed PATH block without replacing unrelated profile content. |
| Other dotfiles | No `.bashrc`, `.zshrc`, `.vimrc`, `.tmux.conf`, `.gitconfig`, `.ssh/config`, `.cargo/config.toml`, `.npmrc` | Linux dotfiles are not already installed here. One public SSH key file exists; no `authorized_keys`. No key material was copied. |
| GitHub CLI | HTTPS git protocol, `co: pr checkout`, interactive prompts enabled | Portable non-secret preferences; authentication remains per user. |

The installed `ChatGPT.app` is version **26.901.41600** with bundle ID **`com.openai.codex`**. Its visible filename is not a reliable way to select an ordinary ChatGPT cask. Preserve this installation and use bundle identity when planning a fresh install.

Balun 0.1.1 and Tributary 0.6.2 are self-contained app bundles with embedded GTK/GStreamer runtimes. Their launchers isolate runtime lookup from Homebrew. The nine requested formulae match local GTK/Rust development needs; these libraries are not evidence that packaged Balun/Tributary need Homebrew at runtime.

| Local checkout | Revision at audit | Branch/state |
| --- | --- | --- |
| `~/balun` (`jm2/balun`) | `1f7a1e4` | `codex/macos-runtime-fixes`, clean |
| `~/tributary` (`jm2/tributary`) | `3e5d333` | `main`, **8 modified paths** |
| `~/CroMagRally` (`jm2/CroMagRally`) | `e10e692` | `master`, clean |
| `~/Quake-III-Arena` (`jm2/Quake-III-Arena`) | `204fe36` | `master`, clean |
| `~/kisakcod` (`jm2/kisakcod`) | `5f29e810` | `master`, clean |

These are development workspaces, not installer payloads. Do not reset, replace, or turn their current branches into workstation defaults. The installed app bundle does not establish the exact source commit used to build it.

## Observed customizations

| Area | Observed setting | Proposed treatment |
| --- | --- | --- |
| Appearance/locale | Dark; `en-US` / `en_US`; U.S. keyboard | Reproduce selected preferences; language changes may require a new login. |
| Keyboard | `KeyRepeat=2`, `InitialKeyRepeat=15`; Lock Screen shortcut `@l` (Command-L) | Manage those specific typed keys; preserve other shortcuts. |
| Mouse/trackpad | Natural scrolling off; tap-to-click off; secondary click on; three-finger drag off | Reproduce intent using the applicable device domains, not host UUIDs. |
| Text | Capitalization and period substitution enabled globally; confirmation when closing changed documents enabled | Preserve observed choices instead of applying a generic developer-defaults list. |
| Dock | Auto-hide; tile and magnified size 128; magnification on; minimize into app; recent apps off | Apply individual preferences after installs. |
| Hot corners | Upper left `2`; upper right `12`; lower corners `1`; modifiers zero | Preserve raw values in snapshot; verify named UI behavior on target macOS before implementation. |
| Finder | Path/status/sidebar on; internal/external/removable/server volumes on Desktop; icon view `icnv`; search `SCev`; new-window target `PfHm`; extensions visible | Reproduce explicit keys. Do not copy window history or alias/bookmark blobs. |
| Desktop | Click wallpaper to reveal Desktop off; widgets hidden for standard and Stage Manager modes; Desktop itself visible | Reproduce selected WindowManager preferences. |
| iCloud folders | Finder reports iCloud Drive enabled; Desktop and Documents sync flags off | Record for manual account setup, not raw plist replay. |
| Menu bar | Battery percentage enabled; date key `ShowDate=0`, AM/PM enabled; several per-host control-center items recorded | Apply portable preferences only after verifying their current domain. |
| Terminal | Custom **Clear Dark** default/startup profile; SF Mono Regular 12; 120×30; background alpha .95 and blur .5 | Export only this named profile as a future reviewed `.terminal` payload. No terminal history/saved windows. |
| VS Code | `workbench.startupEditor=none`; `workbench.colorTheme=Dark Modern` | Merge only these settings; install the extension list below. |
| BBEdit | BBEdit Light/Dark schemes; smart quotes/dashes, capitalization, spelling correction and text completion off; `MakeBackup=false`, `KeepHistoricalBackups=false` | Record; offer app-specific preferences after confirming which values are deliberate. |
| XRG | Vertical monitor; CPU/GPU/memory/network/disk/battery/temperature graphs; one-second refresh; all network interfaces; customized colors/transparency | Future allowlisted app settings. Sensor IDs, weather station, stocks and geometry are machine/personal data, not general defaults. |
| Default browser | LaunchServices http/https/HTML/default-browser handlers point to Chrome | Preserve existing association; use supported user-facing selection on a new Mac. |
| Fonts | No user-installed fonts; `/Library/Fonts` only Arial Unicode symlink to system font | No additional font manifest inferred. |

Dock order, followed by the Downloads stack:

XRG → App Store → Apps → Google Chrome → Maps → Photos → Messages → FaceTime → Phone → iPhone Mirroring → GrandPerspective → BBEdit → Visual Studio Code → Antigravity → Claude → ChatGPT → TV → Music → Games → Tributary → Balun → System Settings → Windows App → Terminal → Activity Monitor → Steam → Battle.net → GOG Galaxy.

## System services, power, and permissions

- **FileVault on; SIP enabled; Gatekeeper assessments enabled; application firewall disabled.** Guest login is disabled. No DEP/MDM enrollment. These are observed states; the plan does not automatically disable protections to match them.
- Launch override records mark **OpenSSH, Screen Sharing, and SMB enabled**. This is enablement evidence, not an external connectivity test. The Public folder is an SMB share with guest access enabled and share-level `read-only=0`; effective filesystem permissions were not audited. Administrator-only `systemsetup` getters did not complete. SSH/server access lists and network reachability still need review before reproducing sharing.
- AC power: `sleep=0`, `displaysleep=10`, `powermode=2`, wake-on-network on. Battery: `sleep=1`, `displaysleep=2`, `powermode=0`, wake-on-network off. Disk sleep 10 on both. Apply only as an explicit laptop power profile after target-hardware validation.
- macOS automatic download, automatic OS install, system-data/security updates, and App Store auto-update preference keys are true. No user crontab. No Homebrew service jobs found. No automatic reboot job added by the observed setup.
- Network service names: USB multi-gigabit Ethernet, Thunderbolt Bridge, Wi-Fi. No nonstandard hosts entries. No `fstab` or `sysctl.conf` found. No printers/default printer. Network addresses, Wi-Fi credentials and VPN secrets were not copied.
- Zero registered system extensions. `/Library/Extensions` contains HighPointIOP and HighPointRR bundles with image-era timestamps; presence alone does not establish they were custom-installed or loaded. No third-party preference panes or Internet plug-ins found. Audio plug-in directories were listed, not exhaustively audited.
- Content caching preference `Activated=false`. No custom Time Machine policy established from inspected keys; backup destinations were not inventoried.
- User launch files: GoogleUpdater hourly wake, two legacy Keystone placeholder plists, Steam cleanup at login. System launch files: GOG Galaxy communication agent and privileged client service. Archived background registration records also contain GOG auto-launch helper, Weather menu, and Xcode/Windows App Quick Look/importer helpers. Registration metadata does not by itself prove current UI enablement. No custom startup script was identified.
- TCC rows record grants for Claude Accessibility; CUA service Accessibility/Screen Capture; Codex Screen Capture and several user folders/media; Tributary media library; Windows App camera/microphone; and system sharing services. Full Disk Access rows for Terminal and Codex have `auth_value=0`. These records are inventory only; reproduce necessary permissions through macOS prompts, not by editing the TCC databases.

## Editor and browser extensions

VS Code extension files and versions:

| Extension | Version |
| --- | --- |
| `google.google-antigravity` | 1.2.0 |
| `ms-vscode.powershell` | 2025.4.0 |
| `golang.go` | 0.56.1 |
| `rust-lang.rust-analyzer` | 0.3.3033 |
| `anthropic.claude-code` | 2.1.261 |
| `openai.chatgpt` | 26.901.22334 |
| `ms-python.vscode-python-envs` | 1.36.0 |
| `ms-python.debugpy` | 2026.6.0 |
| `ms-python.python` | 2026.4.0 |
| `ms-python.vscode-pylance` | 2026.3.1 |

Chrome extension files below include synced/legacy entries. File presence is not proof of enablement or compatibility. Two uBlock Lite versions coexist on disk; they are one extension. Secure Preferences also contains registration-only entries without installed manifests. Safari has the uBlock Origin Lite app installed; its enabled/site-permission state was not verified.

| Chrome extension | ID | Version on disk |
| --- | --- | --- |
| Chrome Remote Desktop | `inomeogfingihgjfjlpeplalcfajhgai` | 2.1 |
| Chrome Web Store Payments | `nmmhkkegccagdldgiimedpiccmgmieda` | 1.0.0.6 |
| Chromebook Recovery Utility | `pocpnlppkickgojjlmhdmidojbmbodfm` | 0.2.3 |
| GNOME Shell integration | `gphhapmejobijbbhgpjhcjognlahblep` | 12.1 |
| Google Docs Offline | `ghbmnnjooekpmoecnnnilnnbdlolhkhi` | 1.109.1 |
| Google Mail Checker | `mihcahmgecmbnbcchbopgniflfhgnkff` | 4.4.4 |
| Google Voice (by Google) | `kcnhkahnjcbndmmehfkdnkjomaanaooo` | 3.0.11 |
| Internet Connection Monitor | `hgccfdagfbilbdbkgmfdmmdfmjjoakfo` | 6.2.1 |
| NBN Availability Checker | `dphlehoebkdjgennbalpfpjnhjojcceo` | 1.2.0 |
| Privacy Badger | `pkehgijcmpdhfbdbbnkijodmdjhbjlgp` | 2026.8.7 |
| SteamDB | `kdbmhfkmnlmbkgbabkdealhhbfhlmmon` | 4.37 |
| The Camelizer | `ghnomdcacenbmilgjigehppbamfndblo` | 3.0.16 |
| uBlock Origin Lite | `ddkjiahejlhfcafbddmgiahcphecmpfh` | 2026.901.1442 |
| uBlock Origin Lite | `ddkjiahejlhfcafbddmgiahcphecmpfh` | 2026.907.2003 |
| User-Agent Switcher for Chrome | `djflhoibgkdhkhhcedjiklpkjnoahfmg` | 2.0.2 |

## Installed application bundles

The following table covers every non-OS bundle found by the scoped scan. Paths expose nested launchers/helpers so they are not mistaken for separate package requests. Architectures come from the main executable; script launchers and embedded components need their own checks. Store app identifiers and minimum OS metadata are in the JSON snapshot.

| App / relative location in `/Applications` | Version | Architecture | Source evidence |
| --- | --- | --- | --- |
| Affinity Photo.app | 1.10.8 | arm64 + x86_64 | App Store receipt |
| Alto's Adventure.app | 1.8.0 | arm64 + x86_64 | App Store receipt |
| Alto's Odyssey.app | 1.3.0 | arm64 + x86_64 | App Store receipt |
| Antigravity.app | 2.12.2 | arm64 | Direct/local |
| Apple Configurator.app | 2.20 | arm64 + x86_64 | App Store receipt |
| Aqara Home.app | 6.4.0 | arm64 | iOS/iPadOS wrapper |
| Balun.app | 0.1.1 | script | Direct/local |
| Battle.net.app | 2.52.11.17778 | x86_64 | Direct/local |
| BBEdit.app | 16.0.3 | arm64 + x86_64 | App Store receipt |
| Billy Frontier.app | 1.1.1 | arm64 + x86_64 | Direct/local |
| Blackmagic Disk Speed Test.app | 3.4.3 | arm64 + x86_64 | App Store receipt |
| Borderlands2.app | 1.8.5 | x86_64 | App Store receipt |
| Bugdom 2.app | 4.0.0 | arm64 + x86_64 | Direct/local |
| Bugdom.app | 1.3.4 | arm64 + x86_64 | Direct/local |
| Channels.app | 7.1.1 | arm64 | iOS/iPadOS wrapper |
| ChatGPT.app | 26.901.41600 | arm64 | Direct/local |
| ClamXav.app | 2.6.4 | x86_64 | App Store receipt |
| Claude.app | 1.46388.4 | arm64 + x86_64 | Direct/local |
| Cro-Mag Rally.app | 3.1.1 | arm64 + x86_64 | Direct/local |
| Crossy Road.app | 7.13.0 | arm64 | iOS/iPadOS wrapper |
| Developer.app | 11.0.2 | arm64 + x86_64 | App Store receipt |
| dhewm3.app | 1.5.5 | arm64 + x86_64 | Direct/local |
| DiRT 4.app | 1.0.1 | x86_64 | App Store receipt |
| DiRT Rally.app | 1.1.4 | x86_64 | App Store receipt |
| ETLegacy/ET Legacy.app | v2.85.0 | arm64 + x86_64 | Direct/local |
| Extreme Tux Racer.app | 0.8.107 | arm64 + x86_64 | App Store receipt |
| GOG Galaxy.app | 2.1.9 | arm64 | Direct/local |
| Google Chrome.app | 152.0.7977.83 | arm64 + x86_64 | Direct/local |
| GrandPerspective.app | 3.7.2 | arm64 + x86_64 | App Store receipt |
| GRIDLegends.app | 1.0 | arm64 | App Store receipt |
| HDHomeRun.app | 20260730 | arm64 + x86_64 | App Store receipt |
| Hex Fiend.app | 2.15 | arm64 + x86_64 | App Store receipt |
| Keka.app | 1.6.7 | arm64 + x86_64 | App Store receipt |
| Keynote Creator Studio.app | 15.3.1 | arm64 + x86_64 | App Store receipt |
| Mactracker.app | 8.2.3 | arm64 + x86_64 | App Store receipt |
| Maelstrom.app | 3.0.7 | x86_64 | Direct/local |
| mahjong 13 tiles.app | 6.0.3 | arm64 | iOS/iPadOS wrapper |
| McDonald's.app | 7.0.410 | arm64 | iOS/iPadOS wrapper |
| Mighty Mike.app | 3.0.2 | arm64 + x86_64 | Direct/local |
| Mini Metro.app | 2.46.0 | x86_64 | App Store receipt |
| Moom Classic.app | 3.2.30 | arm64 + x86_64 | App Store receipt |
| Nanosaur 2.app | 2.1.0 | arm64 + x86_64 | Direct/local |
| Nanosaur.app | 1.4.4 | arm64 + x86_64 | Direct/local |
| Numbers Creator Studio.app | 15.3.1 | arm64 + x86_64 | App Store receipt |
| Offline Games.app | 3.14.1 | arm64 | iOS/iPadOS wrapper |
| Omada.app | 5.3.4 | arm64 | iOS/iPadOS wrapper |
| openglex6.app | 6.4.99 | arm64 + x86_64 | App Store receipt |
| Otto Matic.app | 4.0.1 | arm64 + x86_64 | Direct/local |
| Outline.app | 1.21.0 | arm64 + x86_64 | App Store receipt |
| Pages Creator Studio.app | 15.3.1 | arm64 + x86_64 | App Store receipt |
| Pocket City.app | 1.6.5 | x86_64 | App Store receipt |
| PowerShell.app | 7.6.5 | script | Direct/local |
| Prey2006.app | 1.5.4 | arm64 + x86_64 | Direct/local |
| Prime Video.app | 10.146 | arm64 + x86_64 | App Store receipt |
| Quake3e.app | 1.32e | arm64 + x86_64 | Direct/local |
| Server.app | 5.12.2 | arm64 + x86_64 | App Store receipt |
| Sim City 4 Deluxe Edition.app | 1.2.2 | arm64 + x86_64 | App Store receipt |
| SimCity.app | 1.0.4 | x86_64 | App Store receipt |
| SiteSucker.app | 6.2 | arm64 + x86_64 | App Store receipt |
| Speedtest.app | 1.27 | arm64 + x86_64 | App Store receipt |
| StarCraft II/StarCraft II Editor.app | 5.0.16 (97563) | x86_64 | Direct/local |
| StarCraft II/StarCraft II.app | 1.18.5.3107 | x86_64 | Direct/local |
| StarCraft II/Support/Blizzard Error.app | 2.3.24.0 | x86_64 | Direct/local |
| StarCraft II/Support/BlizzardBrowser/BlizzardBrowser.app | 4.0.4 | x86_64 | Direct/local |
| StarCraft II/Support/SC2Switcher.app | 5.0.16 (97563) | x86_64 | Direct/local |
| StarCraft II/Versions/Base97563/SC2.app | 5.0.16 (97563) | x86_64 | Direct/local |
| StarCraft/StarCraft Launcher.app | 1.18.5.3107 | x86_64 | Direct/local |
| StarCraft/x86_64/Blizzard Error.app | 2.3.24.0 | x86_64 | Direct/local |
| StarCraft/x86_64/StarCraft.app | 1.23.10.13515 | x86_64 | Direct/local |
| Steam.app | 6.1 | arm64 + x86_64 | Direct/local |
| Tailscale.app | 1.102.3 | arm64 + x86_64 | App Store receipt |
| Tapo.app | 3.20.751 | arm64 | iOS/iPadOS wrapper |
| TestFlight.app | 4.3.1 | arm64 + x86_64 | App Store receipt |
| Ting.app | 3.0.4 | arm64 | iOS/iPadOS wrapper |
| Tributary.app | 0.6.2 | script | Direct/local |
| TripView.app | 6.5.6 | arm64 | iOS/iPadOS wrapper |
| uBlock Origin Lite.app | 2026.901.1442 | arm64 + x86_64 | App Store receipt |
| UniFi.app | 10.37.1 | arm64 | iOS/iPadOS wrapper |
| UnrealTournament.app | 469e | arm64 + x86_64 | Direct/local |
| UT2004.app | 3374 | arm64 + x86_64 | Direct/local |
| Visual Studio Code.app | 1.136.1 | arm64 | Direct/local |
| Warcraft III/_retail_/x86_64/BlizzardBrowser/BlizzardBrowser.app | 5.2.3 | x86_64 | Direct/local |
| Warcraft III/_retail_/x86_64/BlizzardBrowser/BlizzardBrowser.app.pre-sign/Contents/Frameworks/BlizzardBrowser Helper (GPU).app | 5.2.3 | x86_64 | Direct/local |
| Warcraft III/_retail_/x86_64/BlizzardBrowser/BlizzardBrowser.app.pre-sign/Contents/Frameworks/BlizzardBrowser Helper (Plugin).app | 5.2.3 | x86_64 | Direct/local |
| Warcraft III/_retail_/x86_64/BlizzardBrowser/BlizzardBrowser.app.pre-sign/Contents/Frameworks/BlizzardBrowser Helper (Renderer).app | 5.2.3 | x86_64 | Direct/local |
| Warcraft III/_retail_/x86_64/BlizzardBrowser/BlizzardBrowser.app.pre-sign/Contents/Frameworks/BlizzardBrowser Helper.app | 5.2.3 | x86_64 | Direct/local |
| Warcraft III/_retail_/x86_64/Warcraft III.app | 2.0.4.23745 | x86_64 | Direct/local |
| Warcraft III/Warcraft III Launcher.app | 1.18.10.3140 | x86_64 | Direct/local |
| Weather Radio.app | 15.4 | arm64 | iOS/iPadOS wrapper |
| WeChat.app | 4.1.13 | arm64 + x86_64 | App Store receipt |
| Windows App.app | 11.4.0 | arm64 + x86_64 | App Store receipt |
| Xcode.app | 26.6 | arm64 | App Store receipt |
| XRG.app | 3.2.1 | arm64 + x86_64 | Direct/local |
| yquake2.app | 8.70 | arm64 + x86_64 | Direct/local |

Steam additionally has **Age of Empires II: Definitive Edition**, app ID `813780`, with a manifest and `AoE2DE` content directory (`StateFlags=4`). This does not establish that it runs on macOS. StarCraft, StarCraft II, Warcraft III, ETLegacy and the source ports have application/game files. User support folders exist for Prey, Quake3, UT2004, Unreal Tournament, YamagiQ2, dhewm3, and ETLegacy. Purchased game assets, account state, saves and per-game configuration are separate restoration work; the shell setup should not manufacture or redistribute them.

Several installed apps are Intel-only, including Battle.net, Maelstrom, ClamXav's x86_64 slice, Borderlands 2, DiRT 4/Rally, Mini Metro, Pocket City, SimCity and Blizzard launchers/games. Rosetta's installer receipt dates to 5 September. Installed legacy apps (notably Server 5.12.2, ClamXav 2.6.4, Affinity Photo 1.10.8 and Moom Classic 3.2.30) need exact-edition/availability decisions before a fresh install can promise to reproduce them.

## Complete Homebrew formula snapshot

“Requested” reflects Homebrew's `installed_on_request` metadata, not a historical guarantee that every other formula was never requested. Versions are evidence, not proposed pins.

| Formula | Installed version | Requested |
| --- | --- | --- |
| `adwaita-icon-theme` | 50.0 | Yes |
| `aom` | 3.15.0 |  |
| `appstream` | 1.2.0 |  |
| `at-spi2-core` | 2.60.6 |  |
| `ca-certificates` | 2026-08-13 |  |
| `cairo` | 1.18.4 |  |
| `dav1d` | 1.5.4 |  |
| `dbus` | 1.16.2_1 |  |
| `faac` | 2.1 |  |
| `faad2` | 2.11.3 |  |
| `fdk-aac` | 2.0.3 |  |
| `ffmpeg` | 9.0.1_1 |  |
| `flac` | 1.5.0 |  |
| `fontconfig` | 2.18.3 |  |
| `freetype` | 2.14.3 |  |
| `fribidi` | 1.0.16 |  |
| `gdk-pixbuf` | 2.44.8 |  |
| `gettext` | 1.0 |  |
| `gh` | 2.100.0 | Yes |
| `giflib` | 6.1.3 |  |
| `glib` | 2.88.3 |  |
| `glib-networking` | 2.80.1 |  |
| `gmp` | 6.3.0 |  |
| `gnutls` | 3.8.13_2 |  |
| `gobject-introspection` | 1.86.0_3 |  |
| `graphene` | 1.10.8 |  |
| `graphite2` | 1.3.15 |  |
| `gsettings-desktop-schemas` | 50.1 |  |
| `gstreamer` | 1.28.7 | Yes |
| `gtk+3` | 3.24.52 |  |
| `gtk4` | 4.22.4 | Yes |
| `harfbuzz` | 14.4.0 |  |
| `hicolor-icon-theme` | 0.18 |  |
| `icu4c@78` | 78.3 |  |
| `imath` | 3.2.3 |  |
| `jemalloc` | 5.3.1 |  |
| `jpeg-turbo` | 3.2.0 |  |
| `json-c` | 0.19 |  |
| `json-glib` | 1.10.8 |  |
| `lame` | 4.0 |  |
| `libadwaita` | 1.9.3 | Yes |
| `libass` | 0.17.5 |  |
| `libcuefile` | r475 |  |
| `libdatrie` | 0.2.14 |  |
| `libdeflate` | 1.26 |  |
| `libepoxy` | 1.5.10 |  |
| `libevent` | 2.1.13 |  |
| `libfyaml` | 0.9.6 |  |
| `libidn2` | 2.3.8 |  |
| `libnghttp2` | 1.70.0 |  |
| `libnice` | 0.1.24 |  |
| `libogg` | 1.3.6 |  |
| `libpng` | 1.6.58 |  |
| `libpsl` | 0.23.3 |  |
| `libreplaygain` | r475 |  |
| `librsvg` | 2.62.3 |  |
| `libshout` | 2.4.6_2 |  |
| `libsndfile` | 1.2.2_1 |  |
| `libsodium` | 1.0.22 |  |
| `libsoup` | 3.6.6 |  |
| `libtasn1` | 4.21.0 |  |
| `libthai` | 0.1.30 |  |
| `libtiff` | 4.7.2 |  |
| `libunibreak` | 7.0 |  |
| `libunistring` | 1.4.2 |  |
| `libusrsctp` | 0.9.5.0_1 |  |
| `libvmaf` | 3.2.0 |  |
| `libvorbis` | 1.3.7 |  |
| `libvpx` | 1.17.0 |  |
| `libx11` | 1.8.13 |  |
| `libxau` | 1.0.12 |  |
| `libxcb` | 1.17.0 |  |
| `libxdmcp` | 1.1.5 |  |
| `libxext` | 1.3.7 |  |
| `libxfixes` | 6.0.2 |  |
| `libxi` | 1.8.3 |  |
| `libxmlb` | 0.3.29 |  |
| `libxrender` | 0.9.12 |  |
| `libxtst` | 1.2.5 |  |
| `little-cms2` | 2.19.1 |  |
| `lz4` | 1.10.0 |  |
| `lzo` | 2.10 |  |
| `mpdecimal` | 4.0.1 |  |
| `mpg123` | 1.33.7 |  |
| `musepack` | r475 |  |
| `ncurses` | 6.6 |  |
| `nettle` | 4.0 |  |
| `opencore-amr` | 0.1.6 |  |
| `openexr` | 3.4.15 |  |
| `openjpeg` | 2.5.4 |  |
| `openjph` | 0.31.0 |  |
| `openssl@3` | 3.6.4 |  |
| `opus` | 1.6.1 |  |
| `orc` | 0.4.43 |  |
| `p11-kit` | 0.26.5 |  |
| `pango` | 1.58.2 |  |
| `pcre2` | 10.48 |  |
| `pixman` | 0.46.4 |  |
| `pkgconf` | 3.0.7 | Yes |
| `py3cairo` | 1.29.1 |  |
| `pygobject3` | 3.58.0 |  |
| `python@3.14` | 3.14.7 |  |
| `readline` | 8.3.3 |  |
| `rtmpdump` | 2.6 |  |
| `rustup` | 1.29.1 | Yes |
| `sdl2-compat` | 2.32.72 |  |
| `sdl3` | 3.4.16 |  |
| `speex` | 1.2.1 |  |
| `sqlite` | 3.53.4 |  |
| `srt` | 1.5.7 |  |
| `srtp` | 2.8.0 |  |
| `svt-av1` | 4.2.0 |  |
| `taglib` | 2.3.2 |  |
| `theora` | 1.2.0 |  |
| `tmux` | 3.7c | Yes |
| `tree` | 2.3.2 | Yes |
| `utf8cpp` | 4.2.0 |  |
| `utf8proc` | 2.11.3 |  |
| `webp` | 1.6.0 |  |
| `x264` | r3222 |  |
| `x265` | 4.3 |  |
| `xorgproto` | 2025.1 |  |
| `xz` | 5.8.3 |  |
| `zstd` | 1.5.7_1 |  |

## OS-supplied application records

These are inventoried, not proposed for reinstallation:

Safari, App Store, Apps, Automator, Books, Calculator, Calendar, Chess, Clock, Contacts, Dictionary, FaceTime, FindMy, Font Book, Freeform, Games, Home, Image Capture, Image Playground, iPhone Mirroring, Journal, Mail, Maps, Messages, Mission Control, Music, News, Notes, Passwords, Phone, Photo Booth, Photos, Podcasts, Preview, QuickTime Player, Reminders, Shortcuts, Siri, Stickies, Stocks, System Settings, TextEdit, Time Machine, Tips, TV, Activity Monitor, AirPort Utility, Audio MIDI Setup, Bluetooth File Exchange, Boot Camp Assistant, ColorSync Utility, Console, Digital Color Meter, Disk Utility, Grapher, Magnifier, Migration Assistant, Print Center, Screen Sharing, Screenshot, Script Editor, System Information, Terminal, VoiceOver Utility, VoiceMemos, Weather.


## Remaining verification boundaries

This is a broad current-state inventory, not a byte-for-byte image or a complete diff against factory macOS. Remaining gaps are login/background-item UI enablement, detailed sharing access lists, backup destinations, complete display/wallpaper configuration, every per-app/game preference, audio plug-ins, app-internal helpers, and software inside external volumes/other users/VMs. App Store account ownership, regional availability, and restore eligibility must be checked when resolving the approved manifest. The archived BTM registry was readable, but its private bitfields were not interpreted as a supported configuration API.

No setup script has been created. This inventory should inform the proposed allowlist; it should not be replayed wholesale.
