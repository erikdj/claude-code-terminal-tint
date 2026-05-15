#!/usr/bin/env bash
# test/test-tty-recovery.sh -- regression test for the /proc-walk fallback
# in on_stop.sh / on_resume.sh.
#
# Newer Claude Code spawns hook child processes with their own session
# (via setsid), so /dev/tty cannot be opened from inside the hook --
# the kernel returns ENXIO because the process has no controlling
# terminal. on_stop.sh and on_resume.sh now walk /proc to find an
# ancestor whose stdio resolves to a /dev/pts/N device and write the
# OSC sequences there instead.
#
# This test verifies that recovery path by:
#   1. Allocating a real PTY pair via `script(1)`.
#   2. Running the hook under `setsid` so /dev/tty fails inside the
#      hook, exactly mirroring the broken CC scenario.
#   3. Reading the PTY output captured by `script` and asserting the
#      OSC bytes are present.
#
# Linux/WSL only (the /proc-walk fallback is /proc-based and the
# `script -c CMD FILE` invocation form is util-linux specific). Skips
# cleanly elsewhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -d /proc ]; then
    echo "SKIP: /proc not available (non-Linux)"
    exit 0
fi
if ! command -v script >/dev/null 2>&1; then
    echo "SKIP: 'script' command not installed"
    exit 0
fi
if ! command -v setsid >/dev/null 2>&1; then
    echo "SKIP: 'setsid' command not installed"
    exit 0
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if LC_ALL=C grep -aq "$pattern" "$file"; then
        echo "ok  -- $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL -- $desc (pattern not found in $file)" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Sanity: confirm /dev/tty really is unwritable inside `setsid` under
# `script`. If this check fails, the rest of the suite is testing the
# fast path rather than the recovery path, and a green result wouldn't
# actually prove the fix works.
DEVTTY_PROBE="$WORK/devtty-probe"
script -q -c "setsid sh -c '( : > /dev/tty ) 2>&1 || echo BLOCKED' </dev/null" \
    "$DEVTTY_PROBE" >/dev/null 2>&1 || true
if LC_ALL=C grep -q 'BLOCKED' "$DEVTTY_PROBE"; then
    echo "ok  -- /dev/tty unwritable inside setsid (recovery path will be exercised)"
    PASS=$((PASS + 1))
else
    echo "SKIP: /dev/tty was writable inside setsid; this environment does not"
    echo "      reproduce the broken CC scenario, so the recovery path cannot"
    echo "      be verified here."
    exit 0
fi

# ---------- on_stop.sh: OSC 11 (bg) and OSC 10 (fg) ------------------------

STOP_OUT="$WORK/stop-capture"
script -q -c "setsid sh '$REPO_ROOT/hooks/on_stop.sh' </dev/null" \
    "$STOP_OUT" >/dev/null 2>&1 || true

assert_grep "$STOP_OUT" $'\033]11;' "on_stop.sh emits OSC 11 (background) to recovered PTY"
assert_grep "$STOP_OUT" $'\033]10;' "on_stop.sh emits OSC 10 (foreground) to recovered PTY"

# ---------- on_resume.sh: OSC 110 (reset fg) and OSC 111 (reset bg) -------

RESUME_OUT="$WORK/resume-capture"
script -q -c "setsid sh '$REPO_ROOT/hooks/on_resume.sh' </dev/null" \
    "$RESUME_OUT" >/dev/null 2>&1 || true

assert_grep "$RESUME_OUT" $'\033]110' "on_resume.sh emits OSC 110 (reset foreground) to recovered PTY"
assert_grep "$RESUME_OUT" $'\033]111' "on_resume.sh emits OSC 111 (reset background) to recovered PTY"

echo
echo "Summary: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
