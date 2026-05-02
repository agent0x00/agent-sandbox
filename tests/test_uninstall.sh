#!/bin/bash
set -euo pipefail

SCRIPT="${1:-./uninstall.sh}"
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

assert_not_exists() {
    if [ ! -e "$1" ]; then
        PASS=$((PASS+1))
        echo "  PASS: $2"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $2 ($1 still exists)" >&2
    fi
}

assert_exists() {
    if [ -e "$1" ]; then
        PASS=$((PASS+1))
        echo "  PASS: $2"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $2 ($1 not found)" >&2
    fi
}

assert_not_contains() {
    if ! grep -qF "$2" "$1" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  PASS: $3"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $3 ('$2' found in $1)" >&2
    fi
}

echo "=== Uninstall script tests ==="

# Set up a fake home with install artifacts
setup_env() {
    local home=$(mktemp -d)
    local prefix="$home/.local"
    local bindir="$prefix/bin"
    mkdir -p "$bindir"

    # Simulate install artifacts
    touch "$bindir/landlock-wrap"
    touch "$bindir/claude-sandboxed"

    # Simulate claude symlink (links to claude-sandboxed)
    ln -sf "$bindir/claude-sandboxed" "$bindir/claude"

    # Simulate agent symlinks
    ln -sf "$bindir/landlock-wrap" "$bindir/gemini-sandboxed"
    ln -sf "$bindir/landlock-wrap" "$bindir/codex-sandboxed"

    # Simulate pre-push hook
    local hookdir="$home/.config/git/hooks"
    mkdir -p "$hookdir"
    touch "$hookdir/pre-push"

    # Simulate profile block
    cat <<'BLOCK' >> "$home/.profile"
# some existing config
export FOO=bar

# >>> agent-sandbox >>>
export LANDLOCK_GITHUB_TOKEN=github_pat_test123
# <<< agent-sandbox <<<
BLOCK

    # Simulate git config pointing to sandbox hook
    # We can't actually set git config in the test, so we'll pass hooksPath
    # as an override to the uninstall script

    echo "$home"
}

# Test 1: Removes binaries and claude symlink
echo "Test 1: Removes binaries and claude symlink"
TEST_HOME=$(setup_env)
exit_code=0
HOME="$TEST_HOME" PREFIX="$TEST_HOME/.local" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "uninstall runs successfully"
assert_not_exists "$TEST_HOME/.local/bin/landlock-wrap" "landlock-wrap removed"
assert_not_exists "$TEST_HOME/.local/bin/claude-sandboxed" "claude-sandboxed removed"
assert_not_exists "$TEST_HOME/.local/bin/claude" "claude symlink removed"
rm -rf "$TEST_HOME"

# Test 2: Removes agent sandboxed symlinks
echo "Test 2: Removes agent symlinks"
TEST_HOME=$(setup_env)
exit_code=0
HOME="$TEST_HOME" PREFIX="$TEST_HOME/.local" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "uninstall runs successfully"
assert_not_exists "$TEST_HOME/.local/bin/gemini-sandboxed" "gemini-sandboxed removed"
assert_not_exists "$TEST_HOME/.local/bin/codex-sandboxed" "codex-sandboxed removed"
rm -rf "$TEST_HOME"

# Test 3: Removes pre-push hook
echo "Test 3: Removes pre-push hook"
TEST_HOME=$(setup_env)
exit_code=0
HOME="$TEST_HOME" PREFIX="$TEST_HOME/.local" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "uninstall runs successfully"
assert_not_exists "$TEST_HOME/.config/git/hooks/pre-push" "pre-push hook removed"
rm -rf "$TEST_HOME"

# Test 4: Removes agent-sandbox block from profile
echo "Test 4: Removes profile block"
TEST_HOME=$(setup_env)
exit_code=0
HOME="$TEST_HOME" PREFIX="$TEST_HOME/.local" PROFILE="$TEST_HOME/.profile" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "uninstall runs successfully"
assert_not_contains "$TEST_HOME/.profile" "agent-sandbox" "agent-sandbox block removed from profile"
assert_not_contains "$TEST_HOME/.profile" "CLAUDE_CODE_EXECUTABLE" "CLAUDE_CODE_EXECUTABLE not in profile"
assert_not_contains "$TEST_HOME/.profile" "LANDLOCK_GITHUB_TOKEN" "LANDLOCK_GITHUB_TOKEN removed from profile"
# Existing content outside the block should be preserved
assert_exists "$TEST_HOME/.profile" "profile still exists"
if grep -qF "FOO=bar" "$TEST_HOME/.profile"; then
    PASS=$((PASS+1))
    echo "  PASS: existing profile content preserved"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: existing profile content was removed" >&2
fi
rm -rf "$TEST_HOME"

# Test 5: Idempotent — running twice doesn't error
echo "Test 5: Idempotent"
TEST_HOME=$(setup_env)
exit_code=0
HOME="$TEST_HOME" PREFIX="$TEST_HOME/.local" PROFILE="$TEST_HOME/.profile" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "first uninstall succeeds"
exit_code=0
HOME="$TEST_HOME" PREFIX="$TEST_HOME/.local" PROFILE="$TEST_HOME/.profile" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "second uninstall succeeds"
rm -rf "$TEST_HOME"

# Test 6: Does not remove non-sandbox claude binary
echo "Test 6: Preserves real claude binary"
TEST_HOME=$(mktemp -d)
PREFIX="$TEST_HOME/.local"
BINDIR="$PREFIX/bin"
mkdir -p "$BINDIR"
# Create a REAL claude binary (not a symlink to claude-sandboxed)
echo '#!/bin/sh' > "$BINDIR/claude"
echo 'echo "real-claude"' >> "$BINDIR/claude"
chmod +x "$BINDIR/claude"
touch "$TEST_HOME/.profile"

exit_code=0
HOME="$TEST_HOME" PREFIX="$PREFIX" PROFILE="$TEST_HOME/.profile" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "uninstall succeeds"
assert_exists "$BINDIR/claude" "real claude binary preserved"
# Verify it's still a regular file, not a symlink
if [ -f "$BINDIR/claude" ] && [ ! -L "$BINDIR/claude" ]; then
    PASS=$((PASS+1))
    echo "  PASS: real claude binary is still a regular file"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: real claude binary was modified" >&2
fi
rm -rf "$TEST_HOME"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
