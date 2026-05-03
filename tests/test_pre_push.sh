#!/bin/bash
set -euo pipefail

HOOK="$(realpath "${1:-./hooks/pre-push}")"
PASS=0
FAIL=0

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

echo "=== Pre-push hook tests ==="

# Test 1: Block push to existing main branch
echo "Test 1: Block push to existing main"
exit_code=0
echo "refs/heads/main deadbeef1234 refs/heads/main cafebabe5678" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "1" "push to existing main is blocked"

# Test 2: Block push to existing master
echo "Test 2: Block push to existing master"
exit_code=0
echo "refs/heads/master deadbeef1234 refs/heads/master cafebabe5678" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "1" "push to existing master is blocked"

# Test: Allow initial push to main (remote doesn't exist yet — remote_sha is all zeros)
echo "Test 3: Allow initial push to main"
exit_code=0
echo "refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main 0000000000000000000000000000000000000000" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "initial push to main allowed (remote_sha is zero)"
echo "Tests 4-5: Force push detection (real repo)"
tmpdir=$(mktemp -d)
cd "$tmpdir"
git init --quiet --initial-branch=trunk
git config user.email "test@test"
git config user.name "test"
echo a > a && git add a && git commit -m "base" --quiet
BASE_SHA=$(git rev-parse HEAD)

# Create feature branch with a commit
git checkout -b feature --quiet
echo feat > a && git add a && git commit -m "feature" --quiet
FEAT_SHA=$(git rev-parse feature)

# Test 4: Normal push to feature branch (BASE is ancestor of FEAT)
echo "Test 4: Allow normal push to feature branch"
exit_code=0
echo "refs/heads/feature $FEAT_SHA refs/heads/feature $BASE_SHA" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "normal push to feature branch allowed"

# Test 5: Block force push — remote FEAT_SHA is NOT ancestor of new commit
echo "Test 5: Block force push"
# Reset feature to trunk, make a different commit → diverges from FEAT_SHA
git checkout trunk --quiet
git checkout -b forced --quiet
echo forced > a && git add a && git commit -m "forced" --quiet
FORCED_SHA=$(git rev-parse forced)
# remote has FEAT_SHA (the original feature tip)
# user pushes FORCED_SHA (divergent, FEAT_SHA not an ancestor)
exit_code=0
echo "refs/heads/feature $FORCED_SHA refs/heads/feature $FEAT_SHA" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "1" "force push to non-main branch blocked"

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
