#!/bin/sh
# claude-code-terminal-tint: UserPromptSubmit / PreToolUse hook -- reset
# the terminal to its default colors so the user sees their normal palette
# whenever Claude is actively working.
#
# Emits OSC 110 (reset foreground) and OSC 111 (reset background) to
# /dev/tty. This restores whatever the user's terminal had configured
# before the "waiting" tint was applied -- we deliberately do NOT set a
# specific "working" color, because that would override the user's own
# theme. Terminals that don't implement OSC 110/111 will pick up default
# colors on their next repaint.
#
# The redirection is wrapped in a subshell so that if /dev/tty cannot be
# opened (e.g. the hook fires from a context without a controlling tty),
# the shell's own "cannot open" message is captured by 2>/dev/null instead
# of leaking to the user.

set -eu

if [ -e /dev/tty ]; then
    ( printf '\033]111\033\\' > /dev/tty ) 2>/dev/null || true
    ( printf '\033]110\033\\' > /dev/tty ) 2>/dev/null || true
fi

exit 0
