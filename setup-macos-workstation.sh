#!/bin/bash
# Native macOS bootstrap. The stdlib Python controller handles structured state.
# Run as the console user; --check/--dry-run never bootstrap prerequisites.
set -eu

usage() {
    cat <<'EOF'
Usage: setup-macos-workstation.sh [--profile core|full] [--check | --dry-run]
       [--no-upgrade] [--with-xcode] [--with-sharing] [--with-power-settings]

Core includes Linux CLI parity, Go, Python/Rust and everyday non-Store apps.
Full adds large toolchains, stable Android SDK/NDK, optional apps and games.
No Store installs or supplemental game data downloads. Sharing/power are opt-in.
Preview modes are offline and read-only. Exit: 0 satisfied/dry-run, 1 error,
2 drift or required manual work. See docs/macos-workstation.md for details.
EOF
}

find_python() {
    local prefix=$1 developer_dir=$2 candidate
    for candidate in "$prefix/bin/python3" "$developer_dir/usr/bin/python3"; do
        [ -n "$developer_dir" ] || [ "$candidate" = "$prefix/bin/python3" ] || continue
        if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}

preview_without_python() {
    local root=$1 profile=$2 mode=$3
    echo "Profile: $profile; mode: $mode (offline)"
    echo 'MANUAL: finish Command Line Tools installation, then rerun for detailed state checks.'
    echo 'PLAN: bootstrap native Homebrew and Python; reconcile the selected manifest:'
    cat "$root/files/macos/manifest.json"
    echo 'PLAN: managed shell/editor/desktop settings; optional flags take effect only on apply.'
    [ "$profile" != full ] || cat "$root/files/macos/game-data.json"
    [ "$mode" = dry-run ] && return 0
    return 2
}

main() {
    local profile=core mode=apply arg root python='' developer_dir='' scratch=''
    local args=("$@")
    while [ "$#" -gt 0 ]; do
        arg=$1
        case "$arg" in
            --help|-h) usage; return 0 ;;
            --profile)
                [ "$#" -ge 2 ] || { echo 'Missing profile' >&2; return 1; }
                profile=$2; shift
                case "$profile" in core|full) ;; *) echo 'Invalid profile' >&2; return 1 ;; esac ;;
            --check|--dry-run)
                [ "$mode" = apply ] || { echo 'Choose one preview mode' >&2; return 1; }
                mode=${arg#--} ;;
            --no-upgrade|--with-xcode|--with-sharing|--with-power-settings) ;;
            *) echo "Unknown argument: $arg" >&2; return 1 ;;
        esac
        shift
    done
    [ "$(uname -s)" = Darwin ] || { echo 'Requires macOS' >&2; return 1; }
    [ "$(uname -m)" = arm64 ] || { echo 'Requires native Apple Silicon shell (no Rosetta)' >&2; return 1; }
    [ "$(sw_vers -productVersion | cut -d . -f 1)" = 26 ] || {
        echo 'Initial support target is macOS 26; other releases are unvalidated.' >&2; return 1;
    }
    [ "$(id -u)" -ne 0 ] || { echo 'Run as your normal user, without sudo.' >&2; return 1; }
    [ -d "$HOME" ] && [ -O "$HOME" ] || { echo 'HOME must be owned by this user.' >&2; return 1; }
    [ ! -x /usr/local/bin/brew ] || { echo 'Intel Homebrew detected; resolve the dual-prefix installation first.' >&2; return 1; }
    root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    # Do not invoke /usr/bin/python3: on a clean Mac it is a CLT installer stub.
    developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null) || developer_dir=''
    python=$(find_python /opt/homebrew "$developer_dir") || python=''
    if [ -z "$python" ]; then
        if [ "$mode" != apply ]; then
            preview_without_python "$root" "$profile" "$mode"
            return "$?"
        fi
        /usr/bin/xcode-select --install || true
        echo 'Complete the Apple Command Line Tools dialog, then rerun.'
        return 2
    fi
    if [ "$mode" = apply ] && [ ! -x /opt/homebrew/bin/brew ]; then
        [ "$(stat -f '%Su' /dev/console)" = "$(id -un)" ] || {
            echo 'Apply requires the logged-in console user.' >&2; return 1;
        }
        scratch=$(mktemp -d "${TMPDIR:-/tmp}/macos-workstation.XXXXXX")
        # The official installer performs its own prefix and sudo checks.
        trap 'rm -rf -- "$scratch"' EXIT
        curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$scratch/brew.sh"
        /bin/bash -n "$scratch/brew.sh"
        /bin/bash "$scratch/brew.sh"
        rm -rf -- "$scratch"
        trap - EXIT
    fi
    export PYTHONDONTWRITEBYTECODE=1
    exec "$python" -B "$root/files/macos/workstation.py" ${args[@]+"${args[@]}"}
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
