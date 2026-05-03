#!/bin/sh
# claude-code-terminal-tint: Stop / Notification hook -- apply "waiting" tint.
#
# Emits OSC 11 (background) and OSC 10 (foreground) sequences to /dev/tty so
# the parent terminal recolors itself, without polluting Claude Code's stdout.
# The terminator used is ST (ESC + backslash), which all major terminals
# accept; see the OSC section of XTerm Control Sequences.

set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$DIR/config.json"

# Defaults -- kept in sync with config.json.
BG="#7a4a00"
FG="#fff7e0"

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

# Write directly to the controlling terminal so Claude Code's stdout/stderr
# pipes (which it may capture) aren't touched.
#
# The redirection is wrapped in a subshell so that if /dev/tty cannot be
# opened (e.g. the hook fires from a context without a controlling tty),
# the shell's own "cannot open" message is captured by 2>/dev/null instead
# of leaking to the user. The bare `> /dev/tty 2>/dev/null` form does not
# suppress the redirection failure because the shell prints it before the
# command's stderr redirection takes effect.
if [ -e /dev/tty ]; then
    ( printf '\033]11;%s\033\\' "$BG" > /dev/tty ) 2>/dev/null || true
    ( printf '\033]10;%s\033\\' "$FG" > /dev/tty ) 2>/dev/null || true
fi

exit 0
