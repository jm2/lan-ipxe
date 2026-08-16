#!/bin/bash
#
# Wreckfest (GOG) offline-LAN identity launcher — Linux/wine.
#
# GOG's Wreckfest build (2024+) ships a THQNOnline "steam_api" wrapper that derives
# the player's SteamID from a hash of GetUserName(). Two machines with the same OS
# username therefore get the same ID and kick each other with "Already Logged In".
# This launcher runs the game under a stable, machine-unique username
# ("<player>.<4 hex>"), persisted across runs, so every install gets a distinct ID
# without DLL swaps or emulators.

set -euo pipefail

CONF="${WRECKFEST_LAN_CONF:-$HOME/.config/wreckfest-lan.conf}"

usage() {
    cat <<'EOF'
Usage: wreckfest-lan.sh [options]

Options:
  -n, --name NAME    Player name for this machine (saved; default: prompt or $USER)
  -d, --dir DIR      Wreckfest install dir (default: WRECKFEST_DIR env, or auto-detect)
  -p, --prefix DIR   WINEPREFIX to use (default: wine default)
      --32           Launch 32-bit Wreckfest.exe instead of Wreckfest_x64.exe
      --server       Run a dedicated LAN server (server_config.cfg)
      --ask          Re-prompt for the player name even if one is saved
      --reset        Forget the saved player name and suffix
  -h, --help         This help
EOF
    exit 0
}

NAME="" DIR_ARG="" PREFIX_ARG="" ARG_32=0 ARG_SERVER=0 ARG_ASK=0 ARG_RESET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name) NAME="$2"; shift 2 ;;
        -d|--dir) DIR_ARG="$2"; shift 2 ;;
        -p|--prefix) PREFIX_ARG="$2"; shift 2 ;;
        --32) ARG_32=1; shift ;;
        --server) ARG_SERVER=1; shift ;;
        --ask) ARG_ASK=1; shift ;;
        --reset) ARG_RESET=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ $ARG_RESET -eq 1 ]]; then
    rm -f "$CONF"
    echo "Forgot saved identity ($CONF)."
fi

GAMEDIR="${DIR_ARG:-${WRECKFEST_DIR:-}}"
if [[ -z "$GAMEDIR" ]]; then
    for d in "/opt/wreckfest-gog" "/opt/wreckfest" "$HOME/GOG Games/Wreckfest" "$PWD"; do
        if [[ -f "$d/Wreckfest_x64.exe" || -f "$d/Wreckfest.exe" ]]; then GAMEDIR="$d"; break; fi
    done
fi
if [[ -z "$GAMEDIR" ]] || [[ ! -f "$GAMEDIR/Wreckfest_x64.exe" && ! -f "$GAMEDIR/Wreckfest.exe" ]]; then
    echo "error: Wreckfest install not found; pass -d/--dir or set WRECKFEST_DIR" >&2
    exit 1
fi

load_conf() {
    [[ -f "$CONF" ]] || return 0
    SAVED_NAME="$(sed -n 's/^NAME=//p' "$CONF" | tail -n1)"
    SAVED_SUFFIX="$(sed -n 's/^SUFFIX=//p' "$CONF" | tail -n1)"
}
sanitize() {
    # Keep chars safe for usernames/env/file paths; cap length.
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-20
}

SAVED_NAME="" SAVED_SUFFIX=""
load_conf

if [[ -z "$NAME" ]]; then
    if [[ $ARG_ASK -eq 1 || -z "$SAVED_NAME" ]] && [[ -t 0 ]]; then
        DEFAULT="$(sanitize "${SAVED_NAME:-$USER}")"
        read -r -p "Player name [${DEFAULT}]: " NAME || true
        NAME="${NAME:-$DEFAULT}"
    else
        NAME="${SAVED_NAME:-$(sanitize "$USER")}"
    fi
fi
NAME="$(sanitize "$NAME")"
if [[ -z "$NAME" ]]; then
    echo "error: player name is empty after sanitizing" >&2
    exit 1
fi

SUFFIX="${SAVED_SUFFIX:-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')}"
if [[ ! "$SUFFIX" =~ ^[0-9a-fA-F]{4}$ ]]; then
    SUFFIX="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
fi

mkdir -p "$(dirname "$CONF")"
if [[ "$NAME" != "$SAVED_NAME" || "$SUFFIX" != "$SAVED_SUFFIX" ]]; then
    printf 'NAME=%s\nSUFFIX=%s\n' "$NAME" "$SUFFIX" > "$CONF"
fi

IDENTITY="${NAME}.${SUFFIX}"

if [[ $ARG_32 -eq 1 ]]; then
    EXE="Wreckfest.exe"
else
    EXE="Wreckfest_x64.exe"
fi
if [[ ! -f "$GAMEDIR/$EXE" ]]; then
    echo "error: $GAMEDIR/$EXE not found" >&2
    exit 1
fi

WINE="${WINE:-wine}"
if ! command -v "$WINE" >/dev/null 2>&1; then
    echo "error: wine not found (set WINE=<path> to override)" >&2
    exit 1
fi

export USER="$IDENTITY"
export WINEUSERNAME="$IDENTITY"
[[ -n "$PREFIX_ARG" ]] && export WINEPREFIX="$PREFIX_ARG"

cd "$GAMEDIR"
echo "Launching $EXE as \"$IDENTITY\" (dir: $GAMEDIR${PREFIX_ARG:+, prefix: $PREFIX_ARG})"

if [[ $ARG_SERVER -eq 1 ]]; then
    [[ -f steam_appid.txt ]] || printf '228380\n' > steam_appid.txt
    [[ -f server_config.cfg ]] || cp initial_server_config.cfg server_config.cfg
    exec "$WINE" "$EXE" -s server_config=server_config.cfg
fi
exec "$WINE" "$EXE"
