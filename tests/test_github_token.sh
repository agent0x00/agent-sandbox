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

echo "=== GitHub token tests ==="

tmpdir=$(mktemp -d)
mkdir "$tmpdir/.git"

# Test 1: GIT_CONFIG_COUNT is set when LANDLOCK_GITHUB_TOKEN is set
echo "Test 1: Git URL rewriting is configured"
exit_code=0
out=$(cd "$tmpdir" && LANDLOCK_GITHUB_TOKEN="ghp_test-token-123" "$BINARY" -- /bin/sh -c 'echo "COUNT=${GIT_CONFIG_COUNT:-unset}"' 2>/dev/null) || exit_code=$?
assert_contains "$out" "COUNT=2" "GIT_CONFIG_COUNT is set to 2"

# Test 2: Token is set in environment
echo "Test 2: Token available"
out=$(cd "$tmpdir" && LANDLOCK_GITHUB_TOKEN="ghp_test-token-123" "$BINARY" -- /bin/sh -c 'echo "TOKEN=${GITHUB_TOKEN:-unset}"' 2>/dev/null)
assert_contains "$out" "TOKEN=ghp_test-token-123" "GITHUB_TOKEN is set"

# Test 3: SSH agent is NOT started (no socket)
echo "Test 3: No SSH agent"
out=$(cd "$tmpdir" && LANDLOCK_GITHUB_TOKEN="ghp_test" "$BINARY" -- /bin/sh -c 'echo "SOCK=${SSH_AUTH_SOCK:-unset}"' 2>/dev/null)
assert_contains "$out" "SOCK=unset" "SSH_AUTH_SOCK is not set"

# Test 4: Without token, neither is set
echo "Test 4: No token, no config"
out=$(cd "$tmpdir" && env -u LANDLOCK_GITHUB_TOKEN "$BINARY" -- /bin/sh -c 'echo "COUNT=${GIT_CONFIG_COUNT:-unset} TOKEN=${GITHUB_TOKEN:-unset}"' 2>/dev/null)
assert_contains "$out" "COUNT=unset" "GIT_CONFIG_COUNT not set without token"
assert_contains "$out" "TOKEN=unset" "GITHUB_TOKEN not set without token"

rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
