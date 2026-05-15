#!/bin/sh
# claude-code-terminal-tint: UserPromptSubmit / PreToolUse hook -- reset
# the terminal to its default colors so the user sees their normal palette
# whenever Claude is actively working.
#
# Emits OSC 110 (reset foreground) and OSC 111 (reset background) to the
# user's terminal device. This restores whatever the user's terminal
# had configured before the "waiting" tint was applied -- we deliberately
# do NOT set a specific "working" color, because that would override the
# user's own theme. Terminals that don't implement OSC 110/111 will pick
# up default colors on their next repaint.
#
# Like on_stop.sh, this hook handles the newer-Claude-Code case where
# the hook child has no controlling terminal: it falls back to walking
# /proc to find an ancestor whose stdio is a /dev/pts/N device.

set -eu

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
    ( printf '\033]111\033\\' > "$TTY_PATH" ) 2>/dev/null || true
    ( printf '\033]110\033\\' > "$TTY_PATH" ) 2>/dev/null || true
fi

exit 0
