# agent-sandbox

OS-level containment for AI agent development. The sandbox gives agents full freedom inside a project directory while preventing damage to the workstation and remote resources. Works with Claude Code, Gemini CLI, Codex, and any other agent.

## Architecture

Three independent layers:

### 1. Workstation containment (Landlock)

A C binary (`landlock-wrap`) uses Linux Landlock to restrict the agent's process tree:

- **Write-allowed**: project root, `/tmp`, `~/.cache`, `~/.local/share`, `~/.local/state`, `~/.config`, `~/.claude`, `~/.agents`, `~/.npm`, `/dev`
- **Read-only**: `/usr`, `/lib`, `/lib64`, `/proc`, `/sys`, `/etc`, `/run`, `~/.nvm`
- **Denied**: Everything else — including HOME (`~`), `~/.ssh`, `~/.bashrc`, `~/.bash_history`, `~/.gnupg`, `~/.profile`

All Landlock filesystem access rights are handled, including `MAKE_FIFO` (named pipe creation) to prevent IPC bypass — named pipes are allowed only within write paths.

Landlock is enforced by the kernel — the agent cannot bypass it.

Project root is auto-detected by walking up from `$PWD` until `.git` or `.sandbox-root` is found.

#### How Claude Code accesses HOME files

Since HOME is entirely blocked by Landlock, `claude-sandboxed` sets up symlinks **before** applying Landlock so Claude Code can still read/write its config files. These symlinks point into `~/.claude/` (which IS write-allowed):

| HOME path | Symlink target |
|-----------|---------------|
| `~/.claude.json` | `~/.claude/config.json` |
| `~/.gitconfig` | `~/.claude/gitconfig` |
| `~/.mcp.json` | `~/.claude/mcp.json` |
| `~/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `~/CLAUDE.local.md` | `~/.claude/CLAUDE.local.md` |
| `~/.claude.json.lock/` | pre-created directory |

### 2. Remote containment (pre-push hooks + PAT scoping)

**Pre-push hook** (global via `core.hooksPath`):
- Blocks pushes to existing `main`/`master` branches (initial setup push is allowed)
- Blocks force pushes to any branch

**GitHub PAT scoping**:
- A fine-grained PAT scoped to specific repos (Contents: Read & Write, Pull requests: Read & Write)
- The wrapper rewrites `git@github.com:` URLs to HTTPS with the PAT
- `SSH_AUTH_SOCK` is unset so SSH auth is impossible
- Sandbox literally cannot push to repos the PAT wasn't granted access to

### 3. Agent integration

The sandbox wraps any agent binary through the same Landlock + PAT boundary. Three integration methods, in order of seamlessness:

**A) Symlink (recommended)**. Create a symlink from the agent's name to `landlock-wrap`. The wrapper auto-discovers the real binary via PATH:
```bash
ln -s ~/.local/bin/landlock-wrap ~/.local/bin/gemini
ln -s ~/.local/bin/landlock-wrap ~/.local/bin/codex
```
When invoked as `gemini`, the wrapper sees its argv[0], strips any suffix (`-sandboxed`, `-wrapper`), finds the real `gemini` in PATH, and execs it after applying Landlock.

**B) `LANDLOCK_WRAP_CMD`**. Set an env var pointing to the agent binary:
```bash
LANDLOCK_WRAP_CMD=/path/to/gemini landlock-wrap --prompt "hello"
```

**C) Wrapper mode**. Prefix the agent command with `landlock-wrap --`:
```bash
landlock-wrap -- gemini --prompt "hello"
```

Landlock containment, PAT scoping, and pre-push hooks apply uniformly regardless of which agent is inside.

## Setup

### Prerequisites

- Linux kernel >= 5.13 (Landlock)
- gcc

### Install

Run the install script. It compiles the sandbox, installs binaries, creates symlinks, sets up the pre-push hook, and prompts for a GitHub PAT.

```bash
./install.sh
```

**Never run with `sudo`** — it installs for the current user only.

The script:
1. Compiles `landlock-wrap.c` with gcc
2. Installs `landlock-wrap` and `claude-sandboxed` to `~/.local/bin/`
3. Replaces `~/.local/bin/claude` with a symlink to `claude-sandboxed`
4. Auto-detects other agents (`gemini`, `codex`) and creates sandboxed symlinks
5. Installs the global pre-push hook
6. Adds `LANDLOCK_GITHUB_TOKEN` to `~/.profile` (if PAT provided)

After install, open a **new terminal** (or `source ~/.profile`) and run `claude`.

### Uninstall

```bash
./uninstall.sh
```

Removes all installed binaries, symlinks, hooks, and profile entries. Preserves the official `claude` binary if it exists (only removes the symlink to `claude-sandboxed`).

### Verify

```bash
make test
```

## Files

```
agent-sandbox/
├── landlock-wrap.c        # Core binary — Landlock, PAT, argv[0] auto-discovery
├── Makefile               # build, test, install, link, unlink, hooks-install, clean
├── install.sh             # Full installation script
├── uninstall.sh           # Clean removal script
├── bin/
│   └── claude-sandboxed   # Claude launcher — version discovery, symlink setup, Landlock exec
├── hooks/
│   └── pre-push           # Global pre-push hook
└── tests/
    ├── test_project_root.sh    # Project root detection
    ├── test_ruleset.sh         # Ruleset contents (paths, exclusions)
    ├── test_enforcement.sh     # Read/write/FIFO/network enforcement
    ├── test_github_token.sh    # PAT token setup and git config
    ├── test_pre_push.sh        # Pre-push hook (main/master block, force-push)
    ├── test_auto_discover.sh   # Agent binary discovery (symlink, env, PATH)
    ├── test_install.sh         # Full install/uninstall lifecycle
    └── test_uninstall.sh       # Cleanup and idempotency
```

## Design decisions & known constraints

### Why HOME is fully blocked

Landlock works at directory granularity — you can allow or deny access to a directory tree, but you cannot selectively allow a single file while blocking its siblings. If HOME were in the read list, `~/.ssh/id_ed25519` would be readable. To prevent this, HOME is absent from all Landlock rulesets. Symlinks redirect the specific files Claude Code needs into `~/.claude/`.

### FIFO containment (IPC)

Landlock implicitly allows any access right not in the handled set. If `MAKE_FIFO` were omitted, a sandboxed process could create named pipes in HOME, `/etc`, or any other path outside the ruleset — an IPC bypass. `landlock-wrap` includes `MAKE_FIFO` in the handled set, allowing FIFOs only in write-allowed paths. `MAKE_CHAR` and `MAKE_BLOCK` are also handled as defense-in-depth (they require `CAP_MKNOD`, already dropped by `NoNewPrivs`).

### stat() metadata leakage

Landlock controls `open()` (via `READ_FILE`, `READ_DIR`, `WRITE_FILE`) but does **not** control `stat()` / `lstat()`. File metadata — size, timestamps, permissions, inode — is visible even for files whose contents are blocked. A sandboxed process can confirm that `~/.ssh/id_ed25519` exists and see its size, but cannot read its contents. This is a kernel-level limitation; closing it would require seccomp-bpf or a PID namespace.

### Why /dev is write-allowed

Git and other tools open `/dev/null` for writing. Landlock treats `/dev/null` as a file beneath `/dev`, so `/dev` must be write-allowed for these operations to succeed. Device files are protected by Unix permissions — the security risk is minimal.

### Why /run is read-only

`/etc/resolv.conf` is a symlink to `/run/systemd/resolve/stub-resolv.conf` on systemd-resolved systems. Without `/run` readable, DNS resolution fails and Claude Code cannot make API calls.

### Why CLAUDE_CODE_EXECUTABLE is set globally

`CLAUDE_CODE_EXECUTABLE` is set in `~/.profile` so external tools (Zed, VS Code) that read this env var to find the Claude binary route through the sandboxed `claude-sandboxed` wrapper. `claude-sandboxed` sets `LANDLOCK_WRAP_CMD` internally so `landlock-wrap` knows which binary to run.

## Reverting

```bash
make unlink    # restore claude symlink to direct version
```
