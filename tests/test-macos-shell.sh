#!/bin/bash
# Run with native Bash 3.2 on macOS; also exercised by the Linux shell job.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-shell-test.XXXXXX")
trap 'rm -rf -- "$TEMP"' EXIT
TEST_HOME="$TEMP/home with spaces"
mkdir -p "$TEST_HOME/.config/lan-ipxe" "$TEST_HOME/bin" "$TEST_HOME/.local/bin" \
    "$TEST_HOME/custom cargo/bin" "$TEST_HOME/custom go/bin" "$TEST_HOME/sdk with spaces/platform-tools" \
    "$TEST_HOME/sdk with spaces/cmdline-tools/latest/bin" "$TEST_HOME/jdk/bin"
cp "$ROOT/files/macos/environment.sh" "$ROOT/files/macos/bashrc" "$TEST_HOME/.config/lan-ipxe/"
export TEST_HOME ROOT

# No interactive settings leak into SSH/scp-like shells.
output=$(HOME="$TEST_HOME" /bin/bash --noprofile --norc -c '. "$ROOT/files/macos/bashrc"; printf "%s" "${_WORKSTATION_BASH_LOADED-unset}"')
[ "$output" = unset ] || { echo 'Noninteractive startup was not inert' >&2; exit 1; }

# Environment respects explicit overrides and is stable across repeated sourcing.
HOME="$TEST_HOME" CARGO_HOME="$TEST_HOME/custom cargo" GOPATH="$TEST_HOME/custom go" \
    ANDROID_HOME="$TEST_HOME/sdk with spaces" JAVA_HOME="$TEST_HOME/jdk" \
    MAKEFLAGS='--jobserver-auth=3,4 -j' EDITOR=nano /bin/bash --noprofile --norc -c '
set -eu
# Check automatic defaults without inheriting runner/user overrides.
unset ANDROID_SDK_ROOT USE_CCACHE
. "$ROOT/files/macos/environment.sh"
first=$PATH
. "$ROOT/files/macos/environment.sh"
[ "$PATH" = "$first" ]
[ "$JAVA_HOME" = "$TEST_HOME/jdk" ]
[ "$ANDROID_HOME" = "$TEST_HOME/sdk with spaces" ]
[ "$ANDROID_SDK_ROOT" = "$ANDROID_HOME" ]
[ "$MAKEFLAGS" = "--jobserver-auth=3,4 -j" ]
[ "$EDITOR" = nano ]
[ "$USE_CCACHE" = 1 ]
case ":$PATH:" in *":$TEST_HOME/custom cargo/bin:"*) ;; *) exit 1 ;; esac
case ":$PATH:" in *":$TEST_HOME/custom go/bin:"*) ;; *) exit 1 ;; esac
case ":$PATH:" in *":$TEST_HOME/sdk with spaces/platform-tools:"*) ;; *) exit 1 ;; esac
'

# No nonexistent Linux paths or invented SDK/NDK default on a core-only home.
HOME="$TEST_HOME" /bin/bash --noprofile --norc -c '
set -eu
unset ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_HOME JAVA_HOME MAKEFLAGS
. "$ROOT/files/macos/environment.sh"
[ -z "${ANDROID_HOME-}" ] && [ -z "${ANDROID_SDK_ROOT-}" ] && [ -z "${ANDROID_NDK_HOME-}" ]
[ -z "${JAVA_HOME-}" ] || [ -x "$JAVA_HOME/bin/java" ]
case "$MAKEFLAGS" in -j[0-9]*) ;; *) exit 1 ;; esac
'

# Original prompt hooks still see failure status; double-source never duplicates.
HOME="$TEST_HOME" TERM=dumb BASH_SILENCE_DEPRECATION_WARNING=1 /bin/bash --noprofile --norc -ic '
set -u
original_hook() { seen=$?; }
PROMPT_COMMAND=original_hook
. "$ROOT/files/macos/bashrc"
first=$PROMPT_COMMAND
. "$ROOT/files/macos/bashrc"
[ "$PROMPT_COMMAND" = "$first" ] || exit 11
# bash-preexec defers hook installation until the first real prompt.
eval "$PROMPT_COMMAND"
case $- in *u*) ;; *) exit 20 ;; esac
false; eval "$PROMPT_COMMAND"
[ "$seen" = 1 ] || exit 12
case "$PS1" in *":("*) ;; *) exit 13 ;; esac
true; eval "$PROMPT_COMMAND"
[ "$seen" = 0 ] || exit 14
case "$PS1" in *":("*) exit 15 ;; esac
shopt -q histappend && shopt -q checkwinsize || exit 16
[ "$PS2" = "> " ] && [ "$PS3" = "> " ] && [ "$PS4" = "+ " ] || exit 17
alias ls | command grep -q "ls -G" || exit 18
alias dir | command grep -q "ls -CGb" || exit 19
'

# Explicitly source the installed login fragment in login and non-login modes.
# The real login/non-login distinction is exercised without touching host profiles.
cat > "$TEST_HOME/.bashrc" <<'EOF'
user_rc_count=$((${user_rc_count:-0} + 1))
. "$HOME/.config/lan-ipxe/bashrc"
EOF
cat > "$TEST_HOME/test-login" <<'EOF'
. "$HOME/.config/lan-ipxe/environment.sh"
case $- in *i*) [ -n "${_WORKSTATION_BASH_LOADED-}" ] || [ ! -r "$HOME/.bashrc" ] || . "$HOME/.bashrc" ;; esac
EOF
for login in '' -l; do
    HOME="$TEST_HOME" TERM=dumb BASH_SILENCE_DEPRECATION_WARNING=1 /bin/bash --noprofile --norc ${login:+"$login"} -ic '
. "$HOME/.bashrc"
. "$HOME/test-login"
[ "$user_rc_count" = 1 ] || exit 21
[ "$_WORKSTATION_BASH_LOADED" = 1 ] || exit 22
'
done

# Existing bash-preexec owns PROMPT_COMMAND; register through its hook array.
HOME="$TEST_HOME" TERM=dumb BASH_SILENCE_DEPRECATION_WARNING=1 /bin/bash --noprofile --norc -ic '
__bp_imported=1
precmd_functions=(existing_precmd)
PROMPT_COMMAND=existing_framework
. "$ROOT/files/macos/bashrc"
[ "$PROMPT_COMMAND" = existing_framework ] || exit 31
[ "${precmd_functions[0]}" = _workstation_prompt ] || exit 32
[ "${precmd_functions[1]}" = existing_precmd ] || exit 33
. "$ROOT/files/macos/bashrc"
[ "${#precmd_functions[@]}" = 2 ] || exit 34
'

if [ -x /bin/zsh ]; then
    HOME="$TEST_HOME" /bin/zsh -f -c 'set -eu; . "$ROOT/files/macos/environment.sh"; first=$PATH; . "$ROOT/files/macos/environment.sh"; [[ $PATH == $first ]]' 2> "$TEMP/zsh-errors"
    [ ! -s "$TEMP/zsh-errors" ] || { cat "$TEMP/zsh-errors" >&2; exit 1; }
fi
printf 'macOS shell behavior tests passed\n'
