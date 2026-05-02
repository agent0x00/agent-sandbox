# agent-sandbox

OS-level containment for AI agent development. The sandbox gives agents full freedom inside a project directory while preventing damage to the workstation and remote resources. Works with Claude Code, Gemini CLI, Codex, and any other agent.

## Architecture

Three independent layers:

### 1. Workstation containment (Landlock)

A C binary (`landlock-wrap`) uses Linux Landlock to restrict the agent's process tree:

- **Write-allowed**: `$PWD`, `/tmp`, `~/.cache`, `~/.config`, `~/.local/share`, `~/.claude`, `~/.agents`
- **Read-only**: system directories (`/usr`, `/etc`, `/proc`, `/sys`), git config
- **Denied**: `~/.ssh`, all other home dir paths

Landlock is enforced by the kernel — the agent cannot bypass it.

Project root is auto-detected by walking up from `$PWD` until `.git` or `.sandbox-root` is found.

### 2. Remote containment (pre-push hooks + PAT scoping)

**Pre-push hook** (global via `core.hooksPath`):
- Blocks all pushes to `main`/`master`
- Blocks force pushes to any branch

**GitHub PAT scoping**:
- A fine-grained PAT scoped to specific repos (Contents: Read & Write)
- The wrapper rewrites `git@github.com:` URLs to HTTPS with the PAT
- `SSH_AUTH_SOCK` is unset so SSH auth is impossible
- Sandbox literally cannot push to repos the PAT wasn't granted access to

### 3. Agent integration

The sandbox wraps any agent binary through the same Landlock + PAT boundary. Three integration methods, in order of seamlessness:

**A) Symlink (recommended)**. Create a symlink from the agent's name to `landlock-wrap`. The wrapper auto-discovers the real binary via PATH:
```bash
ln -s ~/.local/bin/landlock-wrap ~/.local/bin/gemini-cli
ln -s ~/.local/bin/landlock-wrap ~/.local/bin/codex
```
When invoked as `gemini-cli`, the wrapper sees its argv[0], strips any suffix (`-sandboxed`, `-wrapper`), finds the real `gemini-cli` in PATH, and execs it after applying Landlock.

**B) `LANDLOCK_WRAP_CMD`**. Set an env var pointing to the agent binary:
```bash
LANDLOCK_WRAP_CMD=/path/to/gemini-cli landlock-wrap --prompt "hello"
```

**C) Wrapper mode**. Prefix the agent command with `landlock-wrap --`:
```bash
landlock-wrap -- gemini-cli --prompt "hello"
```

Landlock containment, PAT scoping, and pre-push hooks apply uniformly regardless of which agent is inside.

## Setup

### Prerequisites

- Linux kernel ≥ 5.13 (Landlock)
- gcc

### Install

```bash
# Build and install landlock-wrap + launcher scripts
make install

# Install global pre-push hook
make hooks-install
```

### Claude Code

```bash
# Replace claude symlink with sandboxed version
make link
```

This replaces `~/.local/bin/claude` → `claude-sandboxed` → `landlock-wrap` → real claude binary. The launcher auto-discovers the latest Claude version from `~/.local/share/claude/versions/`.

**Zed ACP** — single line in `~/.profile`:
```bash
export CLAUDE_CODE_EXECUTABLE=landlock-wrap
```

The ACP server calls `landlock-wrap` instead of the bundled binary. `landlock-wrap` auto-discovers the latest Claude version from `~/.local/share/claude/versions/`, applies Landlock + PAT, then execs the real Claude. Same model picker, same UI.

### Gemini CLI

Option A (symlink):
```bash
ln -s ~/.local/bin/landlock-wrap ~/.local/bin/gemini-cli-sandboxed
alias gemini-cli='gemini-cli-sandboxed'
```

Option B (alias):
```bash
alias gemini-cli='landlock-wrap -- gemini-cli'
```

### Codex

Option A (symlink):
```bash
ln -s ~/.local/bin/landlock-wrap ~/.local/bin/codex-sandboxed
alias codex='codex-sandboxed'
```

Option B (alias):
```bash
alias codex='landlock-wrap -- codex'
```

### GitHub PAT

1. GitHub → Settings → Developer settings → Fine-grained tokens → Generate new token
2. Resource owner: your account
3. Repository access: "Only select repositories"
4. Permissions (only one needed):
   - **Contents**: Read and write
   - Everything else: No access (default)
5. Add to `~/.profile`:
   ```bash
   export LANDLOCK_GITHUB_TOKEN=github_pat_...
   ```

### Verify

```bash
make test
```

## Files

```
agent-sandbox/
├── landlock-wrap.c       # Core binary — Landlock, PAT, argv[0] auto-discovery
├── Makefile              # build, test, install, link, unlink, hooks-install, clean
├── bin/
│   └── claude-sandboxed  # Claude-specific launcher with version auto-discovery
├── hooks/
│   └── pre-push          # Global pre-push hook
└── tests/
    ├── test_project_root.sh
    ├── test_ruleset.sh
    ├── test_enforcement.sh
    ├── test_github_token.sh
    ├── test_pre_push.sh
    └── test_auto_discover.sh
```

## Reverting

```bash
make unlink    # restore claude symlink to direct version
```
