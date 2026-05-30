#!/usr/bin/env bash
# test/test-install.sh -- regression test for the bash side of the plugin.
#
# Covers:
#   - Hook scripts emit the right escape sequences:
#       on_stop.sh    -- OSC 11 / 10 with the green "waiting" palette
#       on_resume.sh  -- OSC 110 / 111 (reset to default), and NO
#                        hardcoded OSC 11 color set
#   - config.json defines the green "waiting" palette and no longer
#     defines a "working" block.
#   - install.sh registers exactly four hook entries (Stop,
#     UserPromptSubmit, PreToolUse, SessionEnd) -- and explicitly does
#     NOT register anything on Notification, which previously fired
#     spurious tints mid-loop.
#   - Path-independent marker: idempotent re-installs and clean uninstall
#     work even when the plugin lives at a path that does not contain
#     "claude-code-terminal-tint".
#   - Migration: a settings.json pre-seeded with the v0.1.0 layout (four
#     plugin hooks including Notification) is migrated to the new
#     four-hook layout (Notification dropped, SessionEnd added) on
#     re-install.
#   - Pre-existing user hooks survive both install and uninstall.
#   - settings.json round-trips through a JSON parser at every step.
#   - Hook scripts and uninstall produce no stderr without a tty.
#
# Requires: bash, python3, sh. No other dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available" >&2
    exit 0
fi

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t cctt-test)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Plugin path deliberately does NOT contain "claude-code-terminal-tint" so
# we exercise the marker-only path. Same for the fake $HOME.
PLUGIN="$WORK/tint"
FAKE_HOME="$WORK/home"
mkdir -p "$PLUGIN/hooks" "$FAKE_HOME/.claude"
cp "$REPO_ROOT/install.sh"         "$PLUGIN/install.sh"
cp "$REPO_ROOT/uninstall.sh"       "$PLUGIN/uninstall.sh"
cp "$REPO_ROOT/config.json"        "$PLUGIN/config.json"
cp "$REPO_ROOT/hooks/on_stop.sh"   "$PLUGIN/hooks/on_stop.sh"
cp "$REPO_ROOT/hooks/on_resume.sh" "$PLUGIN/hooks/on_resume.sh"

SETTINGS="$FAKE_HOME/.claude/settings.json"

count_ours() {
    python3 - "$SETTINGS" <<'PYEOF'
import json, sys
MARK = "# claude-code-terminal-tint-marker"
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    print(0); sys.exit(0)
n = 0
for arr in (data.get("hooks") or {}).values():
    if isinstance(arr, list):
        for g in arr:
            if isinstance(g, dict):
                for h in g.get("hooks") or []:
                    if isinstance(h, dict):
                        cmd = str(h.get("command", "")).rstrip()
                        if cmd.endswith(MARK):
                            n += 1
print(n)
PYEOF
}

assert_json_valid() {
    python3 - "$SETTINGS" <<'PYEOF' >/dev/null
import json, sys
json.load(open(sys.argv[1]))
PYEOF
}

has_user_hook() {
    python3 - "$SETTINGS" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
arr = (data.get("hooks") or {}).get("Stop") or []
for g in arr:
    if isinstance(g, dict):
        for h in g.get("hooks") or []:
            if isinstance(h, dict) and "user-existing-hook" in str(h.get("command", "")):
                print("yes"); sys.exit(0)
print("no")
PYEOF
}

has_event_key() {
    python3 - "$SETTINGS" "$1" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
print("yes" if sys.argv[2] in (data.get("hooks") or {}) else "no")
PYEOF
}

PASS=0
FAIL=0
assert_eq() {
    local got="$1" want="$2" desc="$3"
    if [ "$got" = "$want" ]; then
        echo "ok  -- $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL -- $desc (expected '$want', got '$got')" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ---------- 0. Sanity guard --------------------------------------------------

case "$PLUGIN" in
    *claude-code-terminal-tint*)
        echo "FAIL -- plugin path '$PLUGIN' contains 'claude-code-terminal-tint'; cannot exercise marker fix" >&2
        exit 1
        ;;
esac
echo "ok  -- plugin path '$PLUGIN' does not contain plugin name"
PASS=$((PASS + 1))

# ---------- 1. Static asset checks (config.json + hook source) --------------

# config.json: green palette under "waiting", no "working" block.
GREEN_BG="$(python3 - "$PLUGIN/config.json" <<'PYEOF'
import json, sys
print(json.load(open(sys.argv[1])).get("waiting", {}).get("background", ""))
PYEOF
)"
assert_eq "$GREEN_BG" "#1f5d3a" "config.json: waiting.background is the green hex"

WORKING_PRESENT="$(python3 - "$PLUGIN/config.json" <<'PYEOF'
import json, sys
print("yes" if "working" in json.load(open(sys.argv[1])) else "no")
PYEOF
)"
assert_eq "$WORKING_PRESENT" "no" "config.json: 'working' block is gone (single-color config)"

# on_stop.sh: must emit OSC 11 (background set) so the green tint applies.
if grep -q '\\033\]11;' "$PLUGIN/hooks/on_stop.sh"; then
    assert_eq "yes" "yes" "on_stop.sh emits OSC 11 (set background)"
else
    assert_eq "no"  "yes" "on_stop.sh emits OSC 11 (set background)"
fi

# on_resume.sh: must emit OSC 110 (reset fg) and OSC 111 (reset bg), and
# must NOT emit OSC 11 with a hardcoded color (the whole point is "go back
# to the user's terminal default", not "set a different fixed color").
if grep -q '\\033\]110' "$PLUGIN/hooks/on_resume.sh"; then
    assert_eq "yes" "yes" "on_resume.sh emits OSC 110 (reset foreground)"
else
    assert_eq "no"  "yes" "on_resume.sh emits OSC 110 (reset foreground)"
fi
if grep -q '\\033\]111' "$PLUGIN/hooks/on_resume.sh"; then
    assert_eq "yes" "yes" "on_resume.sh emits OSC 111 (reset background)"
else
    assert_eq "no"  "yes" "on_resume.sh emits OSC 111 (reset background)"
fi
if grep -q '\\033\]11;' "$PLUGIN/hooks/on_resume.sh"; then
    assert_eq "no"  "yes" "on_resume.sh does NOT emit a hardcoded OSC 11 color set"
else
    assert_eq "yes" "yes" "on_resume.sh does NOT emit a hardcoded OSC 11 color set"
fi

# /dev/tty regression guard. Claude Code captures both stdout and stderr
# from hook child processes (per the hooks docs), so writing OSC bytes
# to >&1 or >&2 swallows them silently without ever reaching the
# terminal emulator. The hooks must write directly to /dev/tty -- the
# controlling terminal device, which remains connected to the user's
# terminal regardless of pipe redirection by the parent process. This
# test catches a regression where someone "simplifies" the code back
# to writing stdout/stderr.
if grep -q '> /dev/tty' "$PLUGIN/hooks/on_stop.sh"; then
    assert_eq "yes" "yes" "on_stop.sh writes OSC sequences to /dev/tty (not stderr)"
else
    assert_eq "no"  "yes" "on_stop.sh writes OSC sequences to /dev/tty (not stderr)"
fi
if grep -q '> /dev/tty' "$PLUGIN/hooks/on_resume.sh"; then
    assert_eq "yes" "yes" "on_resume.sh writes OSC sequences to /dev/tty (not stderr)"
else
    assert_eq "no"  "yes" "on_resume.sh writes OSC sequences to /dev/tty (not stderr)"
fi
if grep -q '> /dev/tty' "$PLUGIN/uninstall.sh"; then
    assert_eq "yes" "yes" "uninstall.sh writes the OSC reset to /dev/tty"
else
    assert_eq "no"  "yes" "uninstall.sh writes the OSC reset to /dev/tty"
fi

# ---------- 2. Fresh install + idempotency on a clean settings.json ---------

# Pre-seed an unrelated user hook + a top-level setting we want preserved.
cat > "$SETTINGS" <<'EOF'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo user-existing-hook"}]}
    ]
  },
  "model": "claude-sonnet-4-6"
}
EOF

HOME="$FAKE_HOME" sh "$PLUGIN/install.sh" >/dev/null
assert_json_valid
assert_eq "$(count_ours)"            "4"   "first install registers exactly 4 plugin hook entries"
assert_eq "$(has_event_key Notification)" "no"  "first install does NOT register a Notification hook"
assert_eq "$(has_event_key Stop)"             "yes" "first install registers Stop"
assert_eq "$(has_event_key UserPromptSubmit)" "yes" "first install registers UserPromptSubmit"
assert_eq "$(has_event_key PreToolUse)"       "yes" "first install registers PreToolUse"
assert_eq "$(has_event_key SessionEnd)"       "yes" "first install registers SessionEnd"
assert_eq "$(has_user_hook)" "yes" "pre-existing user hook survives first install"

HOME="$FAKE_HOME" sh "$PLUGIN/install.sh" >/dev/null
assert_json_valid
assert_eq "$(count_ours)" "4" "second install is idempotent (still 4 entries)"

HOME="$FAKE_HOME" sh "$PLUGIN/install.sh" >/dev/null
assert_json_valid
assert_eq "$(count_ours)" "4" "third install is idempotent (still 4 entries)"

# ---------- 3. Migration from v0.1.0 layout ---------------------------------

# Reset settings.json to a v0.1.0-shape: four plugin entries (including a
# Notification one), all bearing our marker. A correct upgrade should
# collapse this to exactly three plugin entries with no Notification key.
python3 - "$SETTINGS" <<'PYEOF'
import json, sys
seed = {
    "hooks": {
        "Stop": [
            {"hooks": [{"type":"command","command":"echo user-existing-hook"}]},
            {"hooks": [{"type":"command","command":"sh /old/plugin/hooks/on_stop.sh # claude-code-terminal-tint-marker"}]},
        ],
        "Notification": [
            {"hooks": [{"type":"command","command":"sh /old/plugin/hooks/on_stop.sh # claude-code-terminal-tint-marker"}]},
        ],
        "UserPromptSubmit": [
            {"hooks": [{"type":"command","command":"sh /old/plugin/hooks/on_resume.sh # claude-code-terminal-tint-marker"}]},
        ],
        "PreToolUse": [
            {"hooks": [{"type":"command","command":"sh /old/plugin/hooks/on_resume.sh # claude-code-terminal-tint-marker"}], "matcher":"*"},
        ],
    },
    "model": "claude-sonnet-4-6",
}
with open(sys.argv[1], "w") as f:
    json.dump(seed, f, indent=2)
PYEOF

HOME="$FAKE_HOME" sh "$PLUGIN/install.sh" >/dev/null
assert_json_valid
assert_eq "$(count_ours)"                  "4"  "v0.1.0->current upgrade yields 4 plugin entries"
assert_eq "$(has_event_key Notification)"  "no" "v0.1.0 Notification entry is removed on upgrade"
assert_eq "$(has_event_key SessionEnd)"    "yes" "upgrade adds the SessionEnd reset hook"
assert_eq "$(has_user_hook)"               "yes" "user hook on Stop survives v0.1.0->current upgrade"

# ---------- 4. Uninstall + idempotent uninstall ------------------------------

HOME="$FAKE_HOME" sh "$PLUGIN/uninstall.sh" >/dev/null 2>&1
assert_json_valid
assert_eq "$(count_ours)"   "0"   "uninstall removes all plugin hook entries"
assert_eq "$(has_user_hook)" "yes" "user hook survives uninstall"

HOME="$FAKE_HOME" sh "$PLUGIN/uninstall.sh" >/dev/null 2>&1
assert_json_valid
assert_eq "$(count_ours)"   "0"   "second uninstall is a no-op"
assert_eq "$(has_user_hook)" "yes" "user hook still present after second uninstall"

# ---------- 5. Stderr-leak check on all three scripts -----------------------

LEAK_STOP="$(sh "$PLUGIN/hooks/on_stop.sh" </dev/null 2>&1 >/dev/null || true)"
assert_eq "${LEAK_STOP}" "" "on_stop.sh produces no stderr without a tty"

LEAK_RESUME="$(sh "$PLUGIN/hooks/on_resume.sh" </dev/null 2>&1 >/dev/null || true)"
assert_eq "${LEAK_RESUME}" "" "on_resume.sh produces no stderr without a tty"

LEAK_UNINSTALL="$(HOME="$FAKE_HOME" sh "$PLUGIN/uninstall.sh" </dev/null 2>&1 >/dev/null || true)"
assert_eq "${LEAK_UNINSTALL}" "" "uninstall.sh produces no stderr without a tty"

echo
echo "Summary: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
