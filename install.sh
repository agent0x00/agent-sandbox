#!/bin/bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
PROFILE="${PROFILE:-$HOME/.profile}"
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"

BINDIR="$PREFIX/bin"
HOOKDIR="$HOME/.config/git/hooks"

echo "=== agent-sandbox install ==="
echo "PREFIX=$PREFIX"
echo "PROFILE=$PROFILE"

# ---- Compile ----
echo "Building landlock-wrap..."
cd "$SANDBOX_DIR"
gcc -Wall -Wextra -Wno-format-truncation -O2 -o landlock-wrap landlock-wrap.c

# ---- Install binaries ----
install -d "$BINDIR"
install -m 755 landlock-wrap "$BINDIR/landlock-wrap"

# ---- Claude Code setup ----
if [ -d "$HOME/.local/share/claude/versions" ]; then
    echo "Claude Code detected: installing launcher and symlink"
    install -m 755 "$SANDBOX_DIR/bin/claude-sandboxed" "$BINDIR/claude-sandboxed"
    rm -f "$BINDIR/claude"
    ln -sf "$BINDIR/claude-sandboxed" "$BINDIR/claude"
else
    echo "Claude Code not detected (no ~/.local/share/claude/versions), skipping"
fi

# ---- Auto-detect other agents ----
KNOWN_AGENTS="gemini codex"
for agent in $KNOWN_AGENTS; do
    agent_path=$(command -v "$agent" 2>/dev/null || true)
    if [ -n "$agent_path" ] && [ ! -L "$agent_path" ]; then
        echo "Detected $agent at $agent_path: creating sandboxed symlink"
        rm -f "$BINDIR/$agent-sandboxed"
        ln -sf "$BINDIR/landlock-wrap" "$BINDIR/$agent-sandboxed"
    else
        echo "$agent not detected in PATH, skipping"
    fi
done

# ---- Pre-push hook ----
echo "Installing pre-push hook..."
install -d "$HOOKDIR"
install -m 755 "$SANDBOX_DIR/hooks/pre-push" "$HOOKDIR/pre-push"
git config --global core.hooksPath "$HOOKDIR" 2>/dev/null || true

# ---- Profile setup ----
marker="# >>> agent-sandbox >>>"

if ! grep -qF "$marker" "$PROFILE" 2>/dev/null; then
    echo ""
    echo "=== GitHub PAT ==="
    echo "The sandbox uses a fine-grained PAT for git auth and PR creation."
    echo "Create one at: GitHub → Settings → Developer settings → Fine-grained tokens"
    echo "  - Repository access: Only select repositories"
    echo "  - Permissions: Contents → Read and write"
    echo "  - Permissions: Pull requests → Read and write (needed for PR creation)"
    echo ""
    if [ -t 0 ] && [ -e /dev/tty ]; then
        read -r -p "Enter your GitHub PAT (or press Enter to skip): " pat_input </dev/tty || true
    else
        read -r -p "Enter your GitHub PAT (or press Enter to skip): " pat_input || true
    fi

    echo ""
    echo "Adding sandbox config to $PROFILE..."

    claude_exe="$BINDIR/claude-sandboxed"
    if [ -n "$pat_input" ]; then
        cat <<EOF >> "$PROFILE"

# >>> agent-sandbox >>>
export CLAUDE_CODE_EXECUTABLE=$claude_exe
export LANDLOCK_GITHUB_TOKEN=$pat_input
# <<< agent-sandbox <<<
EOF
        echo "  Added CLAUDE_CODE_EXECUTABLE and LANDLOCK_GITHUB_TOKEN to $PROFILE"
    else
        cat <<EOF >> "$PROFILE"

# >>> agent-sandbox >>>
export CLAUDE_CODE_EXECUTABLE=$claude_exe
# Set your GitHub PAT:
# export LANDLOCK_GITHUB_TOKEN=github_pat_...
# <<< agent-sandbox <<<
EOF
        echo "  Added sandbox config (PAT skipped — set it later in $PROFILE)"
    fi
fi

# ---- Summary ----
echo ""
echo "=== Done ==="
echo "Landlock wrapper: $BINDIR/landlock-wrap"
echo "Claude symlink:   $BINDIR/claude -> $BINDIR/claude-sandboxed"
echo "Pre-push hook:    $HOOKDIR/pre-push"
echo "Profile entries:  $PROFILE ($marker block)"
echo ""
if [ -n "${pat_input:-}" ]; then
    echo "PAT configured. Run: source $PROFILE"
else
    echo "PAT not set. To configure later, edit $PROFILE and set LANDLOCK_GITHUB_TOKEN"
fi
