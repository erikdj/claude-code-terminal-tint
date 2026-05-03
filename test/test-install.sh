#!/usr/bin/env bash
# test/test-install.sh -- regression test for installer idempotency, the
# path-independent marker, and the /dev/tty stderr-leak fix.
#
# The plugin is intentionally placed at a path whose components do NOT
# contain the substring "claude-code-terminal-tint", which is exactly the
# case the previous substring-based marker silently mishandled.
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

# Sanity guard: if for some reason the plugin path *does* contain the old
# substring, we'd be testing the wrong thing.
case "$PLUGIN" in
    *claude-code-terminal-tint*)
        echo "FAIL -- plugin path '$PLUGIN' contains 'claude-code-terminal-tint'; cannot exercise marker fix" >&2
        exit 1
        ;;
esac
echo "ok  -- plugin path '$PLUGIN' does not contain plugin name"
PASS=$((PASS + 1))

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

# 1. Fresh install
HOME="$FAKE_HOME" sh "$PLUGIN/install.sh" >/dev/null
assert_json_valid
assert_eq "$(count_ours)" "4" "first install registers exactly 4 plugin hook entries"
assert_eq "$(has_user_hook)" "yes" "pre-existing user hook survives first install"

# 2. Re-running the installer must not duplicate
HOME="$FAKE_HOME" sh "$PLUGIN/install.sh" >/dev/null
assert_json_valid
assert_eq "$(count_ours)" "4" "second install is idempotent (still 4 entries)"

HOME="$FAKE_HOME" sh "$PLUGIN/install.sh" >/dev/null
assert_json_valid
assert_eq "$(count_ours)" "4" "third install is idempotent (still 4 entries)"

# 3. Uninstall removes only our entries
HOME="$FAKE_HOME" sh "$PLUGIN/uninstall.sh" >/dev/null 2>&1
assert_json_valid
assert_eq "$(count_ours)" "0" "uninstall removes all plugin hook entries"
assert_eq "$(has_user_hook)" "yes" "user hook survives uninstall"

# 4. Uninstall is also idempotent (running it again on already-clean settings)
HOME="$FAKE_HOME" sh "$PLUGIN/uninstall.sh" >/dev/null 2>&1
assert_json_valid
assert_eq "$(count_ours)" "0" "second uninstall is a no-op"
assert_eq "$(has_user_hook)" "yes" "user hook still present after second uninstall"

# 5. Stderr-leak check: the hook scripts write to /dev/tty, but when invoked
# without a controlling tty they must NOT leak the shell's "cannot open"
# message to stderr. Run with stdin closed to force the no-tty path.
LEAK_STOP="$(sh "$PLUGIN/hooks/on_stop.sh" </dev/null 2>&1 >/dev/null || true)"
assert_eq "${LEAK_STOP}" "" "on_stop.sh produces no stderr without a tty"

LEAK_RESUME="$(sh "$PLUGIN/hooks/on_resume.sh" </dev/null 2>&1 >/dev/null || true)"
assert_eq "${LEAK_RESUME}" "" "on_resume.sh produces no stderr without a tty"

LEAK_UNINSTALL="$(HOME="$FAKE_HOME" sh "$PLUGIN/uninstall.sh" </dev/null 2>/dev/null 1>/dev/null && \
                  HOME="$FAKE_HOME" sh "$PLUGIN/uninstall.sh" </dev/null 2>&1 >/dev/null || true)"
# The uninstall script also writes the OSC reset to /dev/tty -- same fix.
# We compare against the empty string to assert no shell error leaked through.
assert_eq "${LEAK_UNINSTALL}" "" "uninstall.sh produces no stderr without a tty"

echo
echo "Summary: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
