#!/bin/sh
# claude-code-terminal-tint installer.
#
# Merges hook entries into ~/.claude/settings.json without clobbering existing
# hooks. Re-running the installer updates entries in place (idempotent).
#
# Requires python3 (preinstalled on Ubuntu, WSL Ubuntu, and macOS) for safe
# JSON merging. Validation: the script round-trips the merged structure
# through json.dumps -> json.loads before writing, so the file on disk is
# guaranteed to parse.

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_DIR="$HOME/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found. Install it (Ubuntu: 'sudo apt install python3') and retry." >&2
    exit 1
fi

mkdir -p "$SETTINGS_DIR"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"

# Hook commands. We invoke `sh` explicitly so the .sh files don't need the
# executable bit set, which is a common gotcha on Windows-mounted filesystems.
# NOTE: paths with literal double quotes will not round-trip cleanly. Avoid
# installing this plugin into a directory whose name contains a double quote.
#
# We append a literal sentinel comment so the installer can identify its own
# entries on re-run regardless of where the plugin is cloned. /bin/sh strips
# the trailing comment before execution, so it has no runtime effect.
MARKER="# claude-code-terminal-tint-marker"
STOP_CMD="sh \"$DIR/hooks/on_stop.sh\" $MARKER"
RESUME_CMD="sh \"$DIR/hooks/on_resume.sh\" $MARKER"

python3 - "$SETTINGS" "$STOP_CMD" "$RESUME_CMD" "$MARKER" <<'PYEOF'
import json, os, sys

path, stop_cmd, resume_cmd, mark = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# Load existing settings, tolerating empty or malformed files.
try:
    with open(path) as f:
        text = f.read().strip()
    data = json.loads(text) if text else {}
    if not isinstance(data, dict):
        raise ValueError("settings.json is not a JSON object")
except (json.JSONDecodeError, ValueError) as e:
    print("WARNING: %s; backing up existing file to %s.bak" % (e, path), file=sys.stderr)
    if os.path.exists(path):
        os.replace(path, path + ".bak")
    data = {}

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("WARNING: existing 'hooks' value was not an object; replacing.", file=sys.stderr)
    hooks = {}
    data["hooks"] = hooks

# We identify our own entries by the literal sentinel comment we appended
# to each command above. Matching on the sentinel as a trailing token (rather
# than a bare substring) means the marker is path-independent and cannot be
# accidentally triggered by an unrelated command that happens to mention
# the plugin name in passing.
MARK = mark

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

# Global sweep: remove this plugin's entries from EVERY event before
# re-registering. This is what makes upgrades clean -- e.g. v0.1.0 wired
# a hook on the Notification event that subsequent versions no longer
# use; without this sweep the stale entry would survive a re-install.
for event in list(hooks.keys()):
    arr = hooks[event]
    if not isinstance(arr, list):
        continue
    arr[:] = [g for g in arr if not is_ours(g)]
    if not arr:
        del hooks[event]

def add(event, cmd, matcher=None):
    arr = hooks.setdefault(event, [])
    if not isinstance(arr, list):
        arr = []
        hooks[event] = arr
    entry = {"hooks": [{"type": "command", "command": cmd}]}
    if matcher:
        entry["matcher"] = matcher
    arr.append(entry)

# Green tint when Claude is genuinely waiting on the human (end of turn).
# Per the Claude Code hooks docs, Stop is the once-per-turn event that
# fires after the agentic loop completes; we deliberately do NOT also
# hook Notification, which fires multiple times per turn (permission
# prompts, idle prompts, auth_success, elicitation_*) and produced
# spurious tints in the middle of tool-use loops.
add("Stop", stop_cmd)
# Reset to terminal default whenever Claude is back at work, so the user
# sees their normal terminal theme during long autonomous loops.
add("UserPromptSubmit", resume_cmd)
add("PreToolUse", resume_cmd, matcher="*")
# Reset on the way out, too. Without this the green tint from the final Stop
# event of the session persists in the terminal after Claude Code exits.
# SessionEnd fires once when the session terminates (quit, /exit, Ctrl+D,
# /clear, logout, ...); reusing the resume script clears the tint. We fire on
# every reason -- on /clear the session restarts and the next Stop re-tints,
# so an unconditional reset here is harmless.
add("SessionEnd", resume_cmd)

# Validate by round-tripping through json before writing.
out = json.dumps(data, indent=2)
json.loads(out)
with open(path, "w") as f:
    f.write(out + "\n")

print("Installed claude-code-terminal-tint hooks -> %s" % path)
PYEOF

# Defensive chmod, in case the user prefers to invoke the scripts directly.
chmod +x "$DIR/hooks/on_stop.sh" "$DIR/hooks/on_resume.sh" 2>/dev/null || true

echo "Done. Restart Claude Code (or start a new session) for hooks to take effect."
