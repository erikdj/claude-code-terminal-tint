#!/bin/sh
# claude-code-terminal-tint uninstaller.
#
# Removes our entries from ~/.claude/settings.json and resets the terminal
# colors via OSC 110 / OSC 111 so users aren't left with a tinted terminal.

set -eu

SETTINGS="$HOME/.claude/settings.json"

if [ -f "$SETTINGS" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 not found; cannot safely modify settings.json." >&2
        exit 1
    fi
    python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]

try:
    with open(path) as f:
        text = f.read().strip()
    data = json.loads(text) if text else {}
    if not isinstance(data, dict):
        sys.exit(0)
except json.JSONDecodeError:
    sys.exit(0)

MARK = "# claude-code-terminal-tint-marker"
hooks = data.get("hooks", {}) or {}
if not isinstance(hooks, dict):
    sys.exit(0)

def is_ours(group):
    if not isinstance(group, dict):
        return False
    for h in group.get("hooks", []) or []:
        if not isinstance(h, dict):
            continue
        cmd = str(h.get("command", "")).rstrip()
        if cmd.endswith(MARK):
            return True
    return False

removed = 0
for event in list(hooks.keys()):
    arr = hooks[event]
    if not isinstance(arr, list):
        continue
    before = len(arr)
    arr[:] = [g for g in arr if not is_ours(g)]
    removed += before - len(arr)
    if not arr:
        del hooks[event]
if not hooks and "hooks" in data:
    del data["hooks"]

out = json.dumps(data, indent=2)
json.loads(out)  # validate
with open(path, "w") as f:
    f.write(out + "\n")
print("Removed %d claude-code-terminal-tint hook entr%s." % (removed, "y" if removed == 1 else "ies"))
PYEOF
fi

# Reset terminal background and foreground to defaults. OSC 111 = reset bg,
# OSC 110 = reset fg. Some terminals ignore these; that's fine -- a fresh
# shell will pick up the user's profile colors anyway.
#
# The redirection is wrapped in a subshell so that if /dev/tty cannot be
# opened (e.g. uninstall is being driven from a non-interactive context),
# the shell's own "cannot open" message is captured by 2>/dev/null instead
# of leaking to the user. The bare `> /dev/tty 2>/dev/null` form does not
# suppress the redirection failure because the shell prints it before the
# command's stderr redirection takes effect.
if [ -e /dev/tty ]; then
    ( printf '\033]111\033\\' > /dev/tty ) 2>/dev/null || true
    ( printf '\033]110\033\\' > /dev/tty ) 2>/dev/null || true
fi

echo "Uninstalled. Restart Claude Code for the settings change to take effect."
