#!/bin/bash
set -euo pipefail

SCRIPT="${1:-./install.sh}"
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

assert_exists() {
    if [ -e "$1" ]; then
        PASS=$((PASS+1))
        echo "  PASS: $2"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $2 ($1 not found)" >&2
    fi
}

assert_symlink() {
    if [ -L "$1" ]; then
        PASS=$((PASS+1))
        echo "  PASS: $2"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $2 (not a symlink)" >&2
    fi
}

assert_file_contains() {
    if grep -qF "$2" "$1" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  PASS: $3"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $3 ('$2' not found in $1)" >&2
    fi
}

echo "=== Install script tests ==="

# Set up a fake home for testing
TEST_HOME=$(mktemp -d)
FAKE_PREFIX="$TEST_HOME/.local"
FAKE_PROFILE="$TEST_HOME/.profile"
FAKE_PATH="$FAKE_PREFIX/bin:/usr/bin:/bin"

# Create a fake real binary to simulate agent detection
mkdir -p "$FAKE_PREFIX/bin"

# Simulate Claude Code installed
mkdir -p "$TEST_HOME/.local/share/claude/versions"
echo '#!/bin/sh
echo "claude-v2.1.123"' > "$TEST_HOME/.local/share/claude/versions/2.1.123"
chmod +x "$TEST_HOME/.local/share/claude/versions/2.1.123"

# Simulate Gemini CLI installed
echo '#!/bin/sh
echo "gemini"' > "$FAKE_PREFIX/bin/gemini"
chmod +x "$FAKE_PREFIX/bin/gemini"

# Simulate Codex installed
echo '#!/bin/sh
echo "codex"' > "$FAKE_PREFIX/bin/codex"
chmod +x "$FAKE_PREFIX/bin/codex"

# Test 1: Compiles and installs landlock-wrap
echo "Test 1: Compile and install"
exit_code=0
HOME="$TEST_HOME" PREFIX="$FAKE_PREFIX" PROFILE="$FAKE_PROFILE" PATH="$FAKE_PATH" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "install script runs successfully"
assert_exists "$FAKE_PREFIX/bin/landlock-wrap" "landlock-wrap installed"

# Test 2: Claude sandboxed launcher installed
echo "Test 2: Claude launcher"
assert_exists "$FAKE_PREFIX/bin/claude-sandboxed" "claude-sandboxed installed"
assert_symlink "$FAKE_PREFIX/bin/claude" "claude symlink created"

# Test 3: Auto-detected agent symlinks
echo "Test 3: Agent auto-detection"
assert_symlink "$FAKE_PREFIX/bin/gemini-sandboxed" "gemini symlink created"
assert_symlink "$FAKE_PREFIX/bin/codex-sandboxed" "codex symlink created"

# Test 4: Pre-push hook installed
echo "Test 4: Pre-push hook"
assert_exists "$TEST_HOME/.config/git/hooks/pre-push" "pre-push hook installed"

# Test 5: Profile setup without PAT (non-interactive)
echo "Test 5: Profile setup with PAT"
# Non-interactive run should get commented placeholder since no TTY
# CLAUDE_CODE_EXECUTABLE must be set so external tools (Zed, etc.) route through landlock-wrap
if grep -qF "CLAUDE_CODE_EXECUTABLE=" "$FAKE_PROFILE" 2>/dev/null; then
    PASS=$((PASS+1))
    echo "  PASS: CLAUDE_CODE_EXECUTABLE in profile"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: CLAUDE_CODE_EXECUTABLE should be in profile" >&2
fi
assert_file_contains "$FAKE_PROFILE" "LANDLOCK_GITHUB_TOKEN" "LANDLOCK_GITHUB_TOKEN placeholder in profile"

# Test 6: Interactive PAT prompt — pipe a token
echo "Test 6: PAT prompt accepts token"
TEST_HOME2=$(mktemp -d)
FAKE_PREFIX2="$TEST_HOME2/.local"
FAKE_PROFILE2="$TEST_HOME2/.profile"
FAKE_PATH2="$FAKE_PREFIX2/bin:/usr/bin:/bin"
mkdir -p "$FAKE_PREFIX2/bin"
mkdir -p "$TEST_HOME2/.local/share/claude/versions"
touch "$TEST_HOME2/.local/share/claude/versions/2.1.123"
chmod +x "$TEST_HOME2/.local/share/claude/versions/2.1.123"
# Pipe a token into the script
echo "github_pat_test123" | HOME="$TEST_HOME2" PREFIX="$FAKE_PREFIX2" PROFILE="$FAKE_PROFILE2" PATH="$FAKE_PATH2" bash "$SCRIPT" 2>/dev/null || true
assert_file_contains "$FAKE_PROFILE2" "LANDLOCK_GITHUB_TOKEN=github_pat_test123" "LANDLOCK_GITHUB_TOKEN set from prompt"
rm -rf "$TEST_HOME2"

# Test 7: Idempotent (running twice doesn't break)
echo "Test 7: Idempotent"
exit_code=0
HOME="$TEST_HOME" PREFIX="$FAKE_PREFIX" PROFILE="$FAKE_PROFILE" PATH="$FAKE_PATH" bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_exit "$exit_code" "0" "second run succeeds"

rm -rf "$TEST_HOME"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
