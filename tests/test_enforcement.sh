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

# Test 5: Cannot read .ssh (HOME not in any Landlock ruleset)
echo "Test 5: Cannot read .ssh"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "ls \$HOME/.ssh 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=2" ".ssh read is blocked"

# Test 6: Cannot create FIFO in /etc (read-only path, no make rights)
echo "Test 6: Cannot create FIFO in /etc"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "mkfifo /etc/landlock-test-fifo-\$\$ 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=1" "/etc FIFO creation returns error"
assert_contains "$out" "Permission denied" "/etc FIFO creation shows Permission denied"

# Cleanup FIFO in /etc if it was created (RED phase: FIFO not yet handled)
rm -f /etc/landlock-test-fifo-* 2>/dev/null || true

# Test 7: Cannot create FIFO in HOME (no rule at all)
echo "Test 7: Cannot create FIFO in HOME"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "mkfifo \$HOME/landlock-test-fifo-\$\$ 2>&1; echo result=\$?" 2>/dev/null) || true
assert_contains "$out" "result=1" "HOME FIFO creation returns error"
assert_contains "$out" "Permission denied" "HOME FIFO creation shows Permission denied"

# Test 8: Can create FIFO in project root (write path, MAKE_FIFO granted)
echo "Test 8: Can create FIFO in project root"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "mkfifo project-fifo && echo created && rm project-fifo" 2>/dev/null) || exit_code=$?
assert_exit "$exit_code" "0" "exits 0 creating FIFO in project root"
assert_contains "$out" "created" "FIFO creation in project root allowed"

# Test 9: Can create FIFO in /tmp (write path, MAKE_FIFO granted)
echo "Test 9: Can create FIFO in /tmp"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "mkfifo /tmp/landlock-test-fifo-\$\$ && echo created && rm /tmp/landlock-test-fifo-\$\$" 2>/dev/null) || exit_code=$?
assert_exit "$exit_code" "0" "exits 0 creating FIFO in /tmp"
assert_contains "$out" "created" "FIFO creation in /tmp allowed"

# Test 10: Cannot read ~/.bash_history (HOME not in any ruleset)
# Use cat to test READ_FILE (ls uses stat, which Landlock does not control)
echo "Test 10: Cannot read ~/.bash_history"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "cat \$HOME/.bash_history > /dev/null 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=1" ".bash_history read is blocked"

# Test 11: Cannot read ~/.gnupg (HOME not in any ruleset)
echo "Test 11: Cannot read ~/.gnupg"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "ls \$HOME/.gnupg 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=2" ".gnupg access is blocked"

# Test 12: /tmp write works
echo "Test 12: Can write to /tmp"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "echo ok > /tmp/landlock-test-\$\$ && cat /tmp/landlock-test-\$\$ && rm /tmp/landlock-test-\$\$" 2>/dev/null) || exit_code=$?
assert_exit "$exit_code" "0" "exits 0 writing to /tmp"
assert_eq "$out" "ok" "/tmp write and read works"

# Test 13: Project root read works
echo "Test 13: Can read project root"
echo "readable" > "$tmpdir/readable-file"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "cat readable-file" 2>/dev/null) || exit_code=$?
assert_exit "$exit_code" "0" "exits 0 reading project root file"
assert_eq "$out" "readable" "read file in project root"

# Test 14: /usr read works (needed for tools)
echo "Test 14: Can read /usr"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "ls /usr/share 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=0" "/usr/share is readable"

# Test 15: /proc read works (needed for tools)
echo "Test 15: Can read /proc"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- /bin/sh -c "cat /proc/self/status > /dev/null 2>&1; echo result=\$?" 2>/dev/null) || exit_code=$?
assert_contains "$out" "result=0" "/proc is readable"

# Test 16: Network accessible (Landlock is FS-only, does not restrict network)
echo "Test 16: Network accessible"
exit_code=0
out=$(cd "$tmpdir" && "$BINARY" -- curl -s -o /dev/null -w "%{http_code}" http://example.com 2>/dev/null) || exit_code=$?
assert_exit "$exit_code" "0" "exits 0 connecting to example.com"
assert_eq "$out" "200" "HTTP GET example.com returns 200"

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
