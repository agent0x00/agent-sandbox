# agent-sandbox

OS-level containment for AI agent development. The sandbox gives agents full freedom inside a project directory while preventing damage to the workstation and remote resources.

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

### 3. Integration

- **Terminal**: `~/.local/bin/claude` symlink → `claude-sandboxed` wrapper → `landlock-wrap` → real claude binary
- **Zed ACP**: `CLAUDE_CODE_EXECUTABLE=landlock-wrap` in `~/.profile`

## Setup

### Prerequisites

- Linux kernel ≥ 5.13 (Landlock)
- gcc

### Install

```bash
# Build, install binary and launcher
make install

# Replace claude symlink with sandboxed version
make link

# Install global pre-push hook
make hooks-install
```

### GitHub PAT

1. GitHub → Settings → Developer settings → Fine-grained tokens → Generate new token
2. Repository access: "Only select repositories"
3. Permissions: Contents → Read & Write
4. Add to `~/.profile`:
   ```bash
   export LANDLOCK_GITHUB_TOKEN=github_pat_...
   ```

### Zed ACP

Add to `~/.profile`:
```bash
export CLAUDE_CODE_EXECUTABLE=landlock-wrap
```

### Verify

```bash
make test
```

## Files

```
agent-sandbox/
├── landlock-wrap.c       # Core binary — Landlock enforcement, PAT setup, project root detection
├── Makefile              # build, test, install, link, unlink, hooks-install, clean
├── bin/
│   └── claude-sandboxed  # Launcher that finds latest Claude version and runs sandboxed
├── hooks/
│   └── pre-push          # Global pre-push hook
└── tests/
    ├── test_project_root.sh
    ├── test_ruleset.sh
    ├── test_enforcement.sh
    ├── test_github_token.sh
    └── test_pre_push.sh
```

## Reverting

```bash
make unlink    # restore claude symlink to direct version
```
