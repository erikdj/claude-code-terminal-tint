#!/bin/sh
# claude-code-terminal-tint: UserPromptSubmit / PreToolUse hook -- apply
# "working" tint. Mirrors on_stop.sh but reads the "working" block.

set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$DIR/config.json"

# Defaults -- kept in sync with config.json.
BG="#1f5d3a"
FG="#e8f5e9"

if [ -f "$CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    OVERRIDE="$(python3 - "$CONFIG" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    w = c.get("working", {}) or {}
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

if [ -e /dev/tty ]; then
    printf '\033]11;%s\033\\' "$BG" > /dev/tty 2>/dev/null || true
    printf '\033]10;%s\033\\' "$FG" > /dev/tty 2>/dev/null || true
fi

exit 0
