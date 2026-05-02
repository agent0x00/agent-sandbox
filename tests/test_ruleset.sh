#!/bin/bash
set -euo pipefail

BINARY="$(realpath "${1:-./landlock-wrap}")"
PASS=0
FAIL=0

# Functions defined in common with other test scripts
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

echo "=== Ruleset tests ==="

# Setup: need a project root for these tests
tmpdir=$(mktemp -d)
mkdir "$tmpdir/.git"

# Test 1: Project root is in write-allowed
echo "Test 1: Project root in write paths"
got=$(cd "$tmpdir" && "$BINARY" --dump-ruleset 2>&1)
assert_contains "$got" "write:$tmpdir" "project root is write-allowed"

# Test 2: /tmp is in write-allowed
echo "Test 2: /tmp in write paths"
assert_contains "$got" "write:/tmp" "/tmp is write-allowed"

# Test 3: ~/.ssh is NOT in read or write paths
echo "Test 3: .ssh excluded"
if echo "$got" | grep -qF ".ssh"; then
    FAIL=$((FAIL+1))
    echo "  FAIL: .ssh should not appear in ruleset" >&2
else
    PASS=$((PASS+1))
    echo "  PASS: .ssh excluded from ruleset"
fi

# Test 4: Extra --write paths are added
echo "Test 4: Extra --write paths"
got=$(cd "$tmpdir" && "$BINARY" --dump-ruleset --write /foo/bar 2>&1)
assert_contains "$got" "write:/foo/bar" "extra --write path added"

# Test 5: .bash_history excluded from ruleset
echo "Test 5: bash_history excluded from ruleset"
got=$(cd "$tmpdir" && "$BINARY" --dump-ruleset 2>&1)
if echo "$got" | grep -qF ".bash_history"; then
    FAIL=$((FAIL+1))
    echo "  FAIL: .bash_history should not appear in ruleset" >&2
else
    PASS=$((PASS+1))
    echo "  PASS: .bash_history excluded from ruleset"
fi

# Test 6: .gnupg excluded from ruleset
echo "Test 6: .gnupg excluded from ruleset"
if echo "$got" | grep -qF ".gnupg"; then
    FAIL=$((FAIL+1))
    echo "  FAIL: .gnupg should not appear in ruleset" >&2
else
    PASS=$((PASS+1))
    echo "  PASS: .gnupg excluded from ruleset"
fi

# Test 7: Essential read paths are present
echo "Test 7: Essential read paths present"
assert_contains "$got" "read:/usr"  "/usr is in read paths"
assert_contains "$got" "read:/lib"  "/lib is in read paths"
assert_contains "$got" "read:/lib64" "/lib64 is in read paths"
assert_contains "$got" "read:/proc" "/proc is in read paths"
assert_contains "$got" "read:/etc"  "/etc is in read paths"

# Test 8: Essential write paths are present
echo "Test 8: Essential write paths present"
assert_contains "$got" "write:/tmp" "/tmp is in write paths"
assert_contains "$got" "write:/dev" "/dev is in write paths"

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
