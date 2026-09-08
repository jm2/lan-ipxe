# macOS workstation setup

`setup-macos-workstation.sh` implements the approved [plan](setup-macos-workstation-plan.md) for **native Apple Silicon on macOS 26**, using Apple Bash 3.2 for bootstrap and a Python 3.9+ standard-library controller for structured state. Intel, translated shells and dual Homebrew prefixes are rejected. Other macOS releases need validation before enabling them.

```bash
./setup-macos-workstation.sh --dry-run
./setup-macos-workstation.sh --check
./setup-macos-workstation.sh                 # core
./setup-macos-workstation.sh --profile full
./setup-macos-workstation.sh --no-upgrade
```

Run as the logged-in console user, without wrapping the script in sudo. Individual Apple/package operations request elevation when needed. CLT installation opens Apple's installer and returns 2 until completed; rerun afterward. Homebrew uses its official installer and `/opt/homebrew` prefix. Apply requires 15 GiB free for core or 40 GiB for full as an initial staging check; dependency closures and future releases can require more.

## Profiles

The authoritative package/app list is [manifest.json](../files/macos/manifest.json). Core contains sensible Fedora/Arch CLI parity, including **wget and Go**, Python, Rust/components, CMake/Ninja/ccache, primary editors/agents, everyday non-Store GUI applications, and the observed GTK/GStreamer/libadwaita developer environment. The [package comparison](macos-package-parity.md) records Linux mappings and exceptions.

Full adds OpenJDK/Maven/Gradle, Ruby, GCC/LLVM/lld, additional development libraries (including Vulkan/MoltenVK tools), Android Studio/SDK/NDK, Ollama, optional GUIs, launchers, and native game/engine releases. No Ollama models, emulator/system images, or supplemental game data are downloaded. No daemon is started merely because its formula was installed.

All Mac App Store/mobile apps are excluded, including Xcode installation. An existing Store app with a selected app identity is ignored; its cask edition is not installed over it. Installed unrelated apps, packages, source checkouts, accounts and browser profiles are preserved.

## Android

Core installs Google's native `adb`/`fastboot` archive into `~/Library/Android/sdk/platform-tools`, with its SHA-256 checked against Homebrew's official metadata. It does **not** install the Homebrew platform-tools cask. Full's Google SDK manager uses this same SDK root and takes over platform-tools updates. The Homebrew command-line-tools package supplies only SDK manager itself; every SDK manager invocation passes `--sdk_root`.

Full chooses the highest numeric stable platform, build-tools and NDK paths from `sdkmanager --list --channel=0`. It installs only those packages, keeps other project versions, and records its selections. `--no-upgrade` retains recorded versions and repairs missing selected packages; without a receipt it preserves the newest installed stable version in each category. Android licenses require an interactive terminal; the script never pipes `yes` into license acceptance. SDK manager prefers the full profile's Homebrew JDK: freshly installed Studio's bundled Java can wait on macOS first-launch assessment. Studio's runtime is a fallback if the standalone JDK is unavailable.

Matching `ANDROID_HOME`/`ANDROID_SDK_ROOT` overrides are supported. Conflicting roots or an existing `adb` owned outside the selected root are reported for reconciliation. Shell configuration exports SDK/JDK/NDK paths only when discovered; explicit project overrides remain authoritative. The NDK `current` link tracks the installer-selected version while project-specific versions remain installed.

## Reruns and ownership

Preview modes are offline and read-only: no Homebrew process, native agent/editor execution, network calls, sudo, cache creation, logs, package updates or preferences writes. They inspect local Cellar/Caskroom receipts, app plists, extension records and defaults. Without a real Python interpreter from Homebrew or selected Apple developer tools, the Bash fallback prints the manifests and prerequisite steps. The Apple `/usr/bin/python3` installer stub is never executed. A preview establishes installed state; it cannot establish whether upstream updates are available.

Normal runs update Homebrew metadata once and install/upgrade only selected packages and their necessary dependencies. Formula and cask installs/upgrades pass Homebrew's `--no-ask` flag to accept package/dependency confirmation automatically; separate authentication and license prompts remain interactive. No blanket upgrade, cleanup or removal occurs. `--no-upgrade` disables explicit metadata/package/toolchain upgrades and automatic Brew updates; installing missing packages may still resolve their required dependencies.

Existing non-cask GUI apps keep their native owners and update channels. Cask apps declaring automatic updates retain that behavior. Existing native Codex and Claude Code CLIs are updated by their official installers; other command owners are preserved. PowerShell uses Microsoft's signed ARM64 package. Ookla Speedtest has the same presence-only policy as the other workstation scripts. Native release apps and games are deliberately presence-oriented on reruns: updating a reviewed game pin does not replace an independently installed app. Keep those native apps updated through their upstream channels.

Zed uses its official stable Apple Silicon DMG, verified by bundle ID, signing team and Gatekeeper. Its bundled CLI is linked into `~/.local/bin` without executing it. Homebrew's Zed cask generates completions by launching the CLI during installation; that launch hung on this Mac before the CLI entered its own code. Existing Zed apps and Homebrew metadata are preserved; setup does not invoke that cask or generate its optional completions. Zed's native updater remains responsible for app updates.

Game releases have reviewed repository/tag/asset/SHA-256 records. Cro-Mag Rally uses **jm2/CroMagRally**; the other seven Pangea titles use **jorio/** repositories. An existing Cro-Mag app requires a matching release executable before the script adopts its provenance. A different local build is preserved and reported for manual reconciliation; it is never silently treated as the requested fork. Checksums are checked before mounts/extraction. DMGs mount read-only and are detached; app identity and native executable are checked before staged copies. The moving Codex desktop URL additionally requires the expected signing team, bundle ID and Gatekeeper assessment. No global Gatekeeper/quarantine/security changes occur.

Changed managed files are written atomically, with backups under `~/Library/Application Support/lan-ipxe/workstation/backups/`. The state directory and operational logs are private to the user; logs contain action records, not command/authentication output. Symlinked configuration files and command collisions are reported, not replaced. Bash/Zsh managed blocks preserve existing profile content; Vim uses the shared repository settings through a managed source block. Editor JSONC is merged without discarding unrelated keys/comments. Existing extensions remain installed.

Only the preference allowlist is changed. Structured values merge with unrelated dictionary keys. Terminal imports the named **Clear Dark** profile; Dock reconciliation appends missing selected installed app identities and preserves unrelated tiles/order, including Store tiles. Existing Dock bookmarks are retained in place, never copied from the inventory. Dock/Finder restart at most once, only after actual changes. No forced logout or reboot occurs.

## Optional system phases

- `--with-xcode`: select an already supplied `/Applications/Xcode.app`; report unfinished license/first-launch work. No Store installation or silent license acceptance.
- `--with-sharing`: ensure the current user belongs to Apple's SSH/Screen Sharing access groups and enable Apple's services. Existing group members remain. System Settings may require manual Remote Login/Full Disk Access interaction. No SMB shares, guest access, firewall changes or arbitrary SSH keys are provisioned.
- `--with-power-settings`: apply the inventoried AC/battery sleep, display sleep, wake-on-network and power-mode values only on the validated `MacBookPro18,2`. Unavailable power-source settings are reported. No restart, hibernation or unrelated power settings are changed.

Rosetta is installed through Apple's interactive license flow only when a selected cask declares it needs Rosetta. No user authentication, remote sessions, games or models are launched.

## Manual items and distribution exceptions

- Chromium and MakeMKV casks are currently disabled. Chrome/Firefox are enabled; existing MakeMKV copies remain outside management. GDB needs Darwin signing/privileges, so Apple LLDB supplies native debugging.
- Maelstrom uses the native Mac Source Ports release; its disabled cask is not used.
- Battle.net's fresh installer is interactive and is reported with the official download page. Existing Battle.net clients are retained. Launcher content stays manual.
- UT2004's current patch channel is a preview; existing copies are retained and its data layout is reported. No full-game installer is invoked.
- OpenArena, Tremulous, Maniadrive, Airshipper and Unigine Heaven have no reviewed maintained native ARM64 artifact in this manifest. They remain documented exceptions, rather than unverified source builds or Intel/Linux substitutes.
- Browser extensions/sync, sign-ins, permissions dialogs and app first-launch prompts remain personal actions. Automatic OS updates and existing security settings are preserved.

Full always ends with the [game-data checklist](../files/macos/game-data.json): expanded destination paths, expected files/layout, app identity/version and presence status. It creates no game data directories and neither reads asset contents nor restores/downloads supplemental data. Bundled resources remain in the approved app distributions. Filename presence does not prove playability; missing manual data does not make setup fail. A missing/failed selected engine still affects the result. Custom launch arguments may change an engine's data paths and require manual review.

## Results and validation

Exit codes: **0** satisfied (or valid dry-run), **1** installer/configuration failure, **2** drift or required manual/deferred work. Independent failures are collected while later apps/configuration continue. Review the result counts and manual entries; a successful dry-run does not assert installation is complete.

Apply prints `START` before each action and `WAIT` every 30 seconds for commands that have not returned. Captured checks receive no interactive input and time out after two minutes, terminating their process group so inherited output pipes cannot keep setup waiting. Interactive installers retain terminal input and have no fixed overall time limit. Private `logs/<run-id>.jsonl` action records are appended throughout the run, including before a stall; the final `.json` summary is also retained. Neither log records command output or credentials.

```bash
/bin/bash -n setup-macos-workstation.sh
/bin/bash tests/test-macos-shell.sh
python3 -B tests/test-macos-workstation.py
shellcheck -S warning setup-macos-workstation.sh files/macos/environment.sh files/macos/bashrc tests/test-macos-shell.sh
```

Tests use temporary homes, fake package/system commands and configuration fixtures. On 8 September 2026, the full profile was applied locally on Apple Silicon macOS 26.6.2 and reached the final game-directory report. A second full run with `--no-upgrade` verified the Zed workaround, corrected MediaInfo/Outline Manager identities, Homebrew JDK selection, shell/editor configuration and desktop reconciliation. Wireshark and Google Drive still required administrator authentication, and Android SDK/build-tools/NDK installation required personal license review; those steps were deferred during the agent-driven test.

The standalone Zed download/install path was also exercised in a temporary application directory, including ARM64, signature, signing-team and Gatekeeper checks. The captured-command timeout was observed terminating the stalled Studio Java process and continuing through all remaining phases. Native Bash/Zsh behavior tests, ShellCheck and 22 controller/bootstrap tests passed. A disposable clean macOS installation, optional Sharing/TCC and other opt-in system phases remain untested.

## Verified sources

Sources checked on 8 September 2026: [Homebrew installation](https://docs.brew.sh/Installation), [formula/cask metadata](https://formulae.brew.sh/), [Google SDK manager](https://developer.android.com/tools/sdkmanager), [Codex CLI](https://learn.chatgpt.com/docs/codex/cli), [Codex desktop distribution](https://learn.chatgpt.com/docs/app), [Microsoft PowerShell releases](https://github.com/PowerShell/PowerShell/releases), [Ookla's formula](https://github.com/teamookla/homebrew-speedtest/blob/master/speedtest.rb), [jm2 Cro-Mag Rally](https://github.com/jm2/CroMagRally/releases), [Jorio](https://github.com/jorio), and [Mac Source Ports](https://www.macsourceports.com/). Each source-port data record links its installation documentation; binary/tagged-source checks resolve documented path differences where needed. Older Jorio assets without GitHub digest metadata were downloaded from their named release URLs, checksummed locally, and inspected read-only for bundle IDs and ARM64 executables.
