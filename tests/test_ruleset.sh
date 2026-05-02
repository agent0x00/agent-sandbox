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

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
