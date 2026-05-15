#!/bin/sh
# claude-code-terminal-tint: Stop hook -- apply "waiting" tint.
#
# Fires when the main agent finishes its turn and is genuinely waiting on
# the user. Emits OSC 11 (background) and OSC 10 (foreground) sequences
# to the user's terminal device so the parent terminal recolors itself,
# without polluting Claude Code's stdout. The terminator used is ST
# (ESC + backslash), which all major terminals accept; see the OSC
# section of XTerm Control Sequences.
#
# Newer Claude Code versions spawn hook child processes with their own
# session (setsid), so /dev/tty cannot be opened from inside a hook --
# the open returns ENXIO because the process has no controlling
# terminal. We fall back to walking /proc until we find an ancestor
# whose stdio resolves to a /dev/pts/N (or /dev/tty<N>) device, and
# write the OSC sequences there. This is the Linux/WSL analog of the
# FreeConsole + AttachConsole(-1) recovery used by the PowerShell hooks.

set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$DIR/config.json"

# Defaults -- kept in sync with config.json.
BG="#1f5d3a"
FG="#e8f5e9"

# Best-effort override from config.json. Uses python3 (preinstalled on Ubuntu,
# WSL Ubuntu, and macOS) to avoid pulling in jq as a dependency.
if [ -f "$CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    OVERRIDE="$(python3 - "$CONFIG" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    w = c.get("waiting", {}) or {}
    print("%s\t%s" % (w.get("background", ""), w.get("foreground", "")))
except Exception:
    pass
PYEOF
)"
    if [ -n "${OVERRIDE:-}" ]; then
        OBG="$(printf '%s' "$OVERRIDE" | cut -f1)"
        OFG="$(printf '%s' "$OVERRIDE" | cut -f2)"
        [ -n "$OBG" ] && BG="$OBG"
        [ -n "$OFG" ] && FG="$OFG"
    fi
fi

# Resolve the path of the user's actual terminal device. Prints the path
# on stdout, or empty if none could be found. Tries /dev/tty first (the
# fast path on macOS and on any context that did inherit a controlling
# terminal); then walks /proc on Linux/WSL.
resolve_user_tty() {
    if [ -e /dev/tty ] && ( : > /dev/tty ) 2>/dev/null; then
        printf '%s' /dev/tty
        return 0
    fi
    [ -d /proc ] || return 0
    _pid=$PPID
    _hops=0
    while [ -n "$_pid" ] && [ "$_pid" != "0" ] && [ "$_pid" != "1" ] && [ "$_hops" -lt 16 ]; do
        for _fd in 0 1 2; do
            _target=$(readlink "/proc/$_pid/fd/$_fd" 2>/dev/null) || true
            case "$_target" in
                /dev/pts/*|/dev/tty[0-9]*)
                    printf '%s' "$_target"
                    return 0
                    ;;
            esac
        done
        # /proc/<pid>/stat: "PID (comm with possible spaces) state PPID ..."
        # Strip up to and including the last ')' so $rest starts at <state>.
        _stat=$(cat "/proc/$_pid/stat" 2>/dev/null) || break
        _rest=${_stat##*) }
        # shellcheck disable=SC2086
        set -- $_rest
        _pid=$2
        _hops=$((_hops + 1))
    done
    return 0
}

TTY_PATH=$(resolve_user_tty)

if [ -n "$TTY_PATH" ]; then
    ( printf '\033]11;%s\033\\' "$BG" > "$TTY_PATH" ) 2>/dev/null || true
    ( printf '\033]10;%s\033\\' "$FG" > "$TTY_PATH" ) 2>/dev/null || true
fi

exit 0
