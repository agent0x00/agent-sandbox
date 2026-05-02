#!/bin/bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
PROFILE="${PROFILE:-$HOME/.profile}"
BINDIR="$PREFIX/bin"

echo "=== agent-sandbox uninstall ==="

rm -f "$BINDIR/landlock-wrap"
rm -f "$BINDIR/claude-sandboxed"

# Remove claude symlink only if it points to claude-sandboxed
if [ -L "$BINDIR/claude" ] && [ "$(readlink "$BINDIR/claude")" = "claude-sandboxed" ]; then
    rm -f "$BINDIR/claude"
fi

# Remove agent sandboxed symlinks
for agent in gemini codex; do
    if [ -L "$BINDIR/${agent}-sandboxed" ]; then
        rm -f "$BINDIR/${agent}-sandboxed"
    fi
done

# Remove pre-push hook
HOOKDIR="$HOME/.config/git/hooks"
if [ -f "$HOOKDIR/pre-push" ]; then
    rm -f "$HOOKDIR/pre-push"
    echo "Pre-push hook removed."
fi

# Unset git hooksPath if it points to the sandbox hook dir
current_hooks=$(git config --global core.hooksPath 2>/dev/null || true)
if [ "$current_hooks" = "$HOOKDIR" ]; then
    git config --global --unset core.hooksPath 2>/dev/null || true
    echo "Git hooksPath restored."
fi

# Remove agent-sandbox block from profile
marker="# >>> agent-sandbox >>>"
if grep -qF "$marker" "$PROFILE" 2>/dev/null; then
    sed -i '/# >>> agent-sandbox >>>/,/# <<< agent-sandbox <<</d' "$PROFILE"
    echo "Profile block removed."
fi

echo "Binaries removed."
