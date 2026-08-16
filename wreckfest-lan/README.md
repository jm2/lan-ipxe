# wreckfest-lan

Offline-LAN identity launchers for the GOG build of Wreckfest (Windows + Linux/wine).
No batch files, no Node.js, no Goldberg emulator, no DLL swapping — two small scripts.

## Problem

GOG's offline Wreckfest installer bundles a THQNOnline "steam_api" wrapper in place of
real Steamworks. In 2024+ builds this wrapper derives the player's SteamID from a hash
of `GetUserName()`:

* Two machines with the same OS username get the **same ID** → the server kicks one of
  them with **"Already Logged In. Retry?"** (notorious on wine, where every default
  Lutris/Bottles prefix is `steamuser`).
* (Older GOG builds, ≤2023, hardcoded the same dummy ID `99642141755572224` for
  *everyone* — see the original
  [Wreckfest_GOG_offline_lan_mode_patch](https://github.com/juj/Wreckfest_GOG_offline_lan_mode_patch).
  Those builds still need that Goldberg-based patch; these scripts do not help there.)

## Fix

`GetUserName()` reads its result from the calling process's environment:
`USERNAME` on Windows, wine's `USER` mapping on Linux. Each launcher:

1. Asks once for a player name and generates a random 4-hex suffix, persisting both
   (`~/.config/wreckfest-lan.conf` / `%LOCALAPPDATA%\wreckfest-lan\config.txt`), so the
   identity is **unique per install and stable across runs** (unlike the Goldberg
   launcher, which randomized the ID every launch).
2. Starts the game with that as its username → GOG's own wrapper computes a distinct
   SteamID per machine. No files in the game dir are modified; saves stay where they
   were.

Verified against GOG build 1.0o-2 (Sep 2025): wrapper returns
`hash(username)`-derived IDs like `0x0160022d0fe8b070`, persona name is a generic
`"Player"` (no more OS-username leaks to public servers).

## Usage

Linux/wine:

    ./wreckfest-lan.sh                       # auto-detects /opt/wreckfest-gog etc.
    ./wreckfest-lan.sh -n Rincewind          # set player name for this machine
    ./wreckfest-lan.sh -p ~/.wreckfest/wine  # explicit WINEPREFIX
    ./wreckfest-lan.sh --server              # dedicated LAN server (server_config.cfg)

Windows (PowerShell 5.1+):

    .\Start-WreckfestLan.ps1
    .\Start-WreckfestLan.ps1 -Name Rincewind -Dir 'C:\GOG Games\Wreckfest'
    .\Start-WreckfestLan.ps1 -Server

Note: the first `wreckfest-lan.sh` run with a custom identity creates a new
`C:\users\<identity>` profile mapping inside the wine prefix (pointing at the same
`$HOME`); game saves are unaffected.

## Limits / notes

* The dedicated server still authenticates with THQ Nordic's online backend
  (`*.thqonline.net`), so the **host** needs internet; joining clients do not.
  This is a property of the game, unchanged by these scripts.
* In-game player names come from the game's own profile, not this identity; the
  multiplayer list shows everyone as `Player` regardless (stock GOG behavior).
* If a future GOG build changes the ID derivation, uniqueness may regress; re-verify
  with two same-username clients before a LAN party.
