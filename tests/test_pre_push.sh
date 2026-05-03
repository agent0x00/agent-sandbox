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

# Create a main branch for testing
git branch main trunk

# Test 1: Default (no protect-main config) — push to main allowed
echo "Test 1: Default allows push to main"
exit_code=0
echo "refs/heads/main $FEAT_SHA refs/heads/main $BASE_SHA" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "push to main allowed by default"

# Test 2: With hooks.protect-main=true — push to main blocked
echo "Test 2: hooks.protect-main blocks push to main"
git config hooks.protect-main true
exit_code=0
echo "refs/heads/main $FEAT_SHA refs/heads/main $BASE_SHA" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "1" "push to main blocked when hooks.protect-main=true"

# Test 3: hooks.protect-main still allows initial push (zero remote_sha)
echo "Test 3: Initial push to main allowed with protection enabled"
exit_code=0
echo "refs/heads/main $FEAT_SHA refs/heads/main 0000000000000000000000000000000000000000" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "initial push to main allowed (remote_sha is zero)"

# Test 4: master also blocked when protect-main is true
echo "Test 4: hooks.protect-main blocks push to master"
exit_code=0
echo "refs/heads/master $FEAT_SHA refs/heads/master $BASE_SHA" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "1" "push to master blocked when hooks.protect-main=true"

# Test 5: Normal push to feature branch (no protection on feature branches)
echo "Test 5: Allow normal push to feature branch"
exit_code=0
echo "refs/heads/feature $FEAT_SHA refs/heads/feature $BASE_SHA" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "normal push to feature branch allowed"

# Test 6: Block force push — remote FEAT_SHA is NOT ancestor of new commit
echo "Test 6: Block force push"
git checkout trunk --quiet
git checkout -b forced --quiet
echo forced > a && git add a && git commit -m "forced" --quiet
FORCED_SHA=$(git rev-parse forced)
exit_code=0
echo "refs/heads/feature $FORCED_SHA refs/heads/feature $FEAT_SHA" | bash "$HOOK" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "1" "force push blocked"

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
