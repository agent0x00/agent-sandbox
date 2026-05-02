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

assert_exit() {
    local code="$1" expected="$2" msg="$3"
    if [ "$code" -eq "$expected" ]; then
        PASS=$((PASS+1))
        echo "  PASS: $msg"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $msg (exit $code, expected $expected)" >&2
    fi
}

echo "=== Enforcement tests ==="

tmpdir=$(mktemp -d)
mkdir "$tmpdir/.git"

# Test 1: Can create files in project root
echo "Test 1: Write to project root"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "echo ok > test-file && cat test-file && rm test-file" 2>/dev/null) || exit_code=$?
assert_exit "$exit_code" "0" "exits 0 writing to project root"
assert_eq "$out" "ok" "writes file in project root"

# Test 2: Cannot write to /etc
echo "Test 2: Cannot write to /etc"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "touch /etc/landlock-test-$$ 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=1" "/etc write returns error"
assert_contains "$out" "Permission denied" "/etc write shows Permission denied"

# Test 3: Cannot write to HOME (outside project)
echo "Test 3: Cannot write to HOME"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "touch \$HOME/landlock-test-$$ 2>&1; echo result=\$?" 2>/dev/null) || true
assert_contains "$out" "result=1" "writes to HOME blocked"
assert_contains "$out" "Permission denied" "HOME write shows Permission denied"

# Test 4: Can install from npm (write to ~/.cache)
echo "Test 4: Write to cache dirs"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "mkdir -p \$HOME/.cache/testdir && echo ok" 2>/dev/null) || exit_code=$?
assert_exit "$exit_code" "0" "exits 0 writing to cache"
assert_eq "$out" "ok" "writes to ~/.cache allowed"
rm -rf "$HOME/.cache/testdir"

# Test 5: Cannot read .ssh
echo "Test 5: Cannot read .ssh"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "ls \$HOME/.ssh 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=2" ".ssh read is blocked"

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
