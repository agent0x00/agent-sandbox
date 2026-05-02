#!/bin/bash
set -euo pipefail

PASS=0
FAIL=0

assert_eq() {
    if [ "$1" = "$2" ]; then
        PASS=$((PASS+1))
        echo "  PASS: $3"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $3 (got '$1', expected '$2')" >&2
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

assert_not_contains() {
    if ! grep -qF "$2" "$1" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  PASS: $3"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $3 ('$2' should not be in $1)" >&2
    fi
}

echo "=== CLAUDE_CODE_EXECUTABLE tests ==="

# Test against the real profile
PROFILE="$HOME/.profile"

# Test 1: CLAUDE_CODE_EXECUTABLE is set (not the typo LAUDE_CODE_EXECUTABLE)
echo "Test 1: Correct variable name"
assert_not_contains "$PROFILE" "export LAUDE_CODE_EXECUTABLE=" "LAUDE_CODE_EXECUTABLE (typo) not in profile"
assert_file_contains "$PROFILE" "CLAUDE_CODE_EXECUTABLE" "CLAUDE_CODE_EXECUTABLE is in profile"

# Test 2: Value points to an existing executable
echo "Test 2: Value is a valid executable"
VALUE=$(grep 'CLAUDE_CODE_EXECUTABLE=' "$PROFILE" | head -1 | sed 's/.*=//')
if [ -n "$VALUE" ] && [ -x "$VALUE" ]; then
    PASS=$((PASS+1))
    echo "  PASS: CLAUDE_CODE_EXECUTABLE='$VALUE' is executable"
elif [ -n "$VALUE" ] && [ -x "$(which "$VALUE" 2>/dev/null)" ]; then
    PASS=$((PASS+1))
    echo "  PASS: CLAUDE_CODE_EXECUTABLE='$VALUE' resolves in PATH"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: CLAUDE_CODE_EXECUTABLE='$VALUE' not executable" >&2
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
