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

echo "=== Project root detection tests ==="

# Test 1: Finds .git in $PWD
echo "Test 1: Finds .git in CWD"
tmpdir=$(mktemp -d)
mkdir "$tmpdir/.git"
got=$(cd "$tmpdir" && "$BINARY" --print-project-root 2>&1)
assert_eq "$got" "$tmpdir" "detects .git in current directory"
rm -rf "$tmpdir"

# Test 2: Walks up tree from subdirectory
echo "Test 2: Walks up tree from subdirectory"
tmpdir=$(mktemp -d)
mkdir "$tmpdir/.git"
mkdir -p "$tmpdir/a/b/c"
got=$(cd "$tmpdir/a/b/c" && "$BINARY" --print-project-root 2>&1)
assert_eq "$got" "$tmpdir" "walks up to find .git from nested subdirectory"
rm -rf "$tmpdir"

# Test 3: .sandbox-root marker
echo "Test 3: Detects .sandbox-root marker"
tmpdir=$(mktemp -d)
mkdir "$tmpdir/.sandbox-root"
got=$(cd "$tmpdir" && "$BINARY" --print-project-root 2>&1)
assert_eq "$got" "$tmpdir" "detects .sandbox-root in current directory"
rm -rf "$tmpdir"

# Test 4: No marker found
echo "Test 4: No marker found"
tmpdir=$(mktemp -d)
exit_code=0
got=$(cd "$tmpdir" && "$BINARY" --print-project-root 2>&1) || exit_code=$?
assert_eq "$exit_code" "1" "exits with code 1 when no marker found"
assert_eq "$got" "" "outputs nothing when no marker found"
rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
