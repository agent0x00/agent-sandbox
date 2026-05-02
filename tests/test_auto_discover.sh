#!/bin/bash
set -euo pipefail

BINARY="$(realpath "${1:-./landlock-wrap}")"
PASS=0
FAIL=0

assert_eq() {
    local got="$1" expected="$2" msg="$3"
    if [ "$got" = "$expected" ]; then
        PASS=$((PASS+1))
        echo "  PASS: $msg"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $msg (got '$got', expected '$expected')" >&2
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS+1))
        echo "  PASS: $msg"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $msg (needle '$needle' not found)" >&2
    fi
}

echo "=== Agent auto-discovery tests ==="

tmpdir=$(mktemp -d)
mkdir "$tmpdir/.git"

# Test 1: argv[0] discovery — invoked via symlink named after a real binary
echo "Test 1: argv[0] discovery via symlink"
echo '#!/bin/sh
echo "discovered-$@"' > "$tmpdir/my-agent"
chmod +x "$tmpdir/my-agent"
# Create symlink: agent-name → landlock-wrap
ln -sf "$BINARY" "$tmpdir/my-agent-wrapper"
# The wrapper sees argv[0]=my-agent-wrapper, strips -wrapper suffix,
# finds my-agent in PATH, execs it
# Note: PATH has $tmpdir first for the real binary
out=$(cd "$tmpdir" && PATH="$tmpdir:$PATH" ./my-agent-wrapper hello world 2>/dev/null) || true
assert_contains "$out" "discovered-hello world" "argv[0] discovery finds real binary via PATH"

# Test 2: Works with generic agent name
echo "Test 2: Generic agent via LANDLOCK_WRAP_CMD"
out=$(cd "$tmpdir" && LANDLOCK_WRAP_CMD=/bin/echo "$BINARY" hello world 2>/dev/null)
assert_contains "$out" "hello world" "runs command via LANDLOCK_WRAP_CMD"

# Test 3: Errors when no discovery possible (no args, no LANDLOCK_WRAP_CMD)
echo "Test 3: Errors when no discovery and no LANDLOCK_WRAP_CMD"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" 2>&1) || exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    PASS=$((PASS+1))
    echo "  PASS: errors when no command to run"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: should have errored" >&2
fi

# Test 4: No args with LANDLOCK_WRAP_CMD succeeds
echo "Test 4: No args with LANDLOCK_WRAP_CMD"
exit_code=0
out=$(cd "$tmpdir" && LANDLOCK_WRAP_CMD=/bin/echo "$BINARY" 2>/dev/null) || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    PASS=$((PASS+1))
    echo "  PASS: runs command via LANDLOCK_WRAP_CMD with no args"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: should have succeeded with LANDLOCK_WRAP_CMD (exit $exit_code)" >&2
fi

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
