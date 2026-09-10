# shellcheck shell=bash
# Shared Bash/Zsh environment. This file must also be safe in noninteractive shells.
# No brew shellenv, Java stub or package commands are executed during startup.
_workstation_path_prepend() {
    [ -d "$1" ] || return 0
    # Remove all existing copies before prepending, including paths with spaces.
    local entry rest=${PATH-} result=''
    while :; do
        entry=${rest%%:*}
        [ "$entry" = "$1" ] || result="${result}${result:+:}${entry}"
        case "$rest" in *:*) rest=${rest#*:} ;; *) break ;; esac
    done
    PATH="$1${result:+:$result}"
}

_workstation_environment() {
    local prefix=/opt/homebrew jdk sdk ndk cpu
    # Zsh otherwise aborts when the optional JDK directory has no matches.
    if [ -n "${ZSH_VERSION-}" ]; then setopt localoptions nonomatch; fi
    _workstation_path_prepend "$prefix/sbin"
    _workstation_path_prepend "$prefix/bin"
    for jdk in curl openssh bison flex m4 texinfo; do
        _workstation_path_prepend "$prefix/opt/$jdk/bin"
    done
    # Homebrew Python's unversioned executables; never override Apple clang.
    _workstation_path_prepend "$prefix/opt/python/libexec/bin"
    _workstation_path_prepend "$prefix/opt/ruby/bin"
    _workstation_path_prepend "$prefix/opt/rustup/bin"
    _workstation_path_prepend "${GOPATH:-$HOME/go}/bin"
    _workstation_path_prepend "${CARGO_HOME:-$HOME/.cargo}/bin"
    _workstation_path_prepend "$HOME/.local/bin"
    _workstation_path_prepend "$HOME/bin"
    if [ -z "${JAVA_HOME+x}" ]; then
        for jdk in "$prefix/opt/openjdk/libexec/openjdk.jdk/Contents/Home" /Library/Java/JavaVirtualMachines/*/Contents/Home; do
            [ -x "$jdk/bin/java" ] || continue
            JAVA_HOME=$jdk; export JAVA_HOME; break
        done
    fi
    [ -z "${JAVA_HOME-}" ] || _workstation_path_prepend "$JAVA_HOME/bin"
    # Explicit overrides remain authoritative, including absent project paths.
    sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
    if [ -d "$sdk" ]; then
        if [ -z "${ANDROID_HOME+x}" ]; then ANDROID_HOME=$sdk; export ANDROID_HOME; fi
        if [ -z "${ANDROID_SDK_ROOT+x}" ]; then ANDROID_SDK_ROOT=$sdk; export ANDROID_SDK_ROOT; fi
        _workstation_path_prepend "$sdk/cmdline-tools/latest/bin"
        _workstation_path_prepend "$sdk/platform-tools"
        # Installer writes this link only when it owns the selected NDK version.
        if [ -z "${ANDROID_NDK_HOME+x}" ]; then
            ndk="$sdk/ndk/current"
            if [ -d "$ndk" ]; then ANDROID_NDK_HOME=$ndk; export ANDROID_NDK_HOME; fi
        fi
    fi
    if [ -z "${MAKEFLAGS+x}" ]; then
        cpu=$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null) || cpu=1
        case "$cpu" in ''|*[!0-9]*) cpu=1 ;; esac
        MAKEFLAGS="-j$cpu"; export MAKEFLAGS
    fi
    : "${EDITOR:=vi}"
    : "${USE_CCACHE:=1}"
    : "${BASH_SILENCE_DEPRECATION_WARNING:=1}"
    export BASH_SILENCE_DEPRECATION_WARNING EDITOR USE_CCACHE PATH
}
_workstation_environment
unset -f _workstation_environment _workstation_path_prepend
