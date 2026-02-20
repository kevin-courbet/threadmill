# Threadmill Architecture

## Overview

Threadmill replaces Superset as the development orchestrator. Native macOS app (Swift/SwiftUI) + lightweight Rust daemon on beast (WSL2). macOS is a visor — all heavy work runs on beast.

## Core Concepts

### Thread
A managed workspace mapped to a project + git worktree + branch. Threads are the primary unit of work. Creating a thread creates a worktree and tmux session on beast. Closing a thread deletes the worktree (or hides it to preserve files). Threads track their lifecycle: `creating → active → closing → closed | hidden | failed`.

### Project
A registered git repository on beast. Added via "Open project" (existing repo) or "Clone repo" (from URL). Projects define:
- Remote path on beast (e.g. `/home/wsl/dev/myautonomy`)
- Setup hooks (global + per-project)
- Terminal presets (what "dev server" means for this project)
- Default branch (main/master)

### Terminal Preset
A named command or set of parallel commands scoped to a project. Examples:
- `dev-server`: `task dev:worktree` (single command)
- `dev-full`: `[task dev:worktree, bun run storybook]` (parallel, each in own pane)
- `opencode`: `opencode` (AI agent session)

Presets are defined in `.threadmill.yml` in the project repo.

## System Architecture

```
┌─────────────────────────────────┐                     ┌──────────────────────────────┐
│  macOS (visor)                  │  single WebSocket    │  beast (WSL2)                │
│                                 │  over SSH tunnel     │                              │
│  Threadmill.app (SwiftUI)       │ ◄──────────────────► │  threadmill-daemon (Rust)    │
│  ├── GRDB (projects, threads,   │                     │  ├── WebSocket server         │
│  │    UI state — cache only)    │                     │  ├── Terminal I/O relay        │
│  ├── SwiftTerm (terminal views) │                     │  ├── Git operations (local)   │
│  └── WebSocket client           │                     │  ├── tmux control             │
│                                 │                     │  ├── Process management       │
│                                 │                     │  └── Hook execution           │
│                                 │                     │                              │
│                                 │                     │  threads.json (daemon state)  │
│                                 │                     │  tmux (persistence layer)     │
│                                 │                     │  ├── session per thread       │
│                                 │                     │  ├── windows per preset       │
│                                 │                     │  └── survives daemon restart  │
└─────────────────────────────────┘                     └──────────────────────────────┘
```

Key: all terminal I/O, RPC commands, and events flow through a **single WebSocket connection** over one SSH tunnel. No per-tab SSH connections.

### Path Resolution

All paths are **beast-local**. The Mac app never accesses beast's filesystem directly — no NFS dependency. Every file operation goes through the daemon over WebSocket (git diff, file browsing, terminal output). The NFS mount (`/Volumes/wsl-dev`) is irrelevant to Threadmill.

This is hardcoded for `beast` — no generic multi-host SSH abstraction:

```yaml
# ~/Library/Application Support/Threadmill/config.yml (on Mac)
host: beast                              # SSH host (matches ~/.ssh/config)
daemon_port: 19990
projects_root: /home/wsl/dev             # default root when browsing for projects
editor: cursor                           # or "code" for VS Code
```

"Open in editor" constructs a Remote SSH URI directly:
```
vscode://vscode-remote/ssh-remote+beast<worktree_path>
```

When adding a project, the daemon provides `project.browse { path }` to list directories on beast — no local file picker needed.

## macOS App (SwiftUI)

### Data Model (GRDB — local cache of daemon state)

The daemon is the single source of truth. GRDB on the Mac is a cache for fast rendering and offline display. On every WebSocket connect, the Mac syncs from the daemon.

```swift
struct Project: Codable, FetchableRecord, PersistableRecord {
    var id: String                // daemon-assigned UUID
    var name: String              // "myautonomy"
    var remotePath: String        // "/home/wsl/dev/myautonomy"
    var defaultBranch: String     // "main"
}

struct Thread: Codable, FetchableRecord, PersistableRecord {
    var id: String                // daemon-assigned UUID
    var projectId: String
    var name: String              // "bridge-test-integration"
    var branch: String
    var worktreePath: String      // "/home/wsl/dev/.threadmill/myautonomy/bridge-test-integration"
    var status: ThreadStatus      // .creating, .active, .closing, .closed, .hidden, .failed
    var createdAt: Date
    var sourceType: SourceType    // .newFeature, .existingBranch, .pullRequest(url)
}

enum ThreadStatus: String, Codable {
    case creating, active, closing, closed, hidden, failed
}

enum SourceType: String, Codable {
    case newFeature
    case existingBranch
    case pullRequest
}
```

### UI Layout

```
┌──────────────────────────────────────────────────────────────┐
│ Threadmill                                    ● connected    │
├──────────────┬───────────────────────────────────────────────┤
│ PROJECTS     │  Thread: bridge-test-integration              │
│              │  myautonomy · feature/bridge-test              │
│ myautonomy   │                                               │
│  ├ bridge-t… │  ┌─────────────────────────────────────────┐  │
│  └ fix-auth  │  │ [Dev Server ●] [OpenCode] [Terminal]    │  │
│              │  ├─────────────────────────────────────────┤  │
│ tigerdata    │  │                                         │  │
│  └ dbt-ref…  │  │  $ task dev:worktree                    │  │
│              │  │  > Server running on :3001               │  │
│              │  │  > Ready in 2.3s                         │  │
│ factorio     │  │                                         │  │
│              │  │                                         │  │
│──────────────│  │                                         │  │
│ + New Thread │  │                                         │  │
│ + Add Project│  │                                         │  │
│              │  └─────────────────────────────────────────┘  │
└──────────────┴───────────────────────────────────────────────┘
```

- **Sidebar**: Projects as sections, threads as items. Status indicators (● running, ○ stopped, ✕ failed).
- **Main area**: Selected thread's terminal view (SwiftTerm). Tab bar for preset terminals.
- **Connection indicator**: top-right shows daemon connection state.

### Add Project Flow

1. User clicks "+ Add Project"
2. Choose method:
   - **Open existing**: enter or browse beast path (e.g. `/home/wsl/dev/myautonomy`). Daemon validates path contains a git repo.
   - **Clone repo**: paste git URL + optional target directory. Daemon runs `git clone` into `/home/wsl/dev/<name>`.
3. Daemon reads `.threadmill.yml` if present, registers project in `threads.json`
4. If no `.threadmill.yml` exists, daemon scaffolds a default one with `terminal` preset only
5. Project appears in sidebar

### New Thread Flow

1. User clicks "+ New Thread"
2. Select project from list
3. Choose source:
   - **New feature**: enter worktree/branch name
   - **Existing branch**: select from remote branches
   - **Pull request**: paste PR URL (extracts branch via `gh`/`glab`)
4. App sends `thread.create` to daemon
5. Daemon returns thread ID immediately with status `creating`
6. Daemon executes async (pushing `thread.progress` events per step):
   a. `git fetch origin`
   b. `git worktree add <path> -b <branch>` (or checkout existing)
   c. Copy files from `copy_from_main` list
   d. Run project setup hooks (from `.threadmill.yml`)
   e. Create tmux session with preset windows (autostart presets)
   f. Status → `active`
7. On failure at any step: status → `failed`, cleanup partial state, report error
8. Cancellable: Mac can send `thread.cancel` to abort mid-create

Per-project mutex prevents concurrent git operations on the same repo.

### Close Thread Flow

1. User right-clicks thread → Close (or Hide)
2. **Close**: daemon kills tmux session, runs teardown hooks, `git worktree remove`, deletes branch if merged
3. **Hide**: daemon kills tmux session only, worktree stays on disk. Thread shows as "hidden" in sidebar. Can be reopened later.

### Terminal Integration (SwiftTerm)

Terminal I/O is **multiplexed through the WebSocket** — no separate SSH connections per tab.

```
SwiftTerm ←→ WebSocket ←→ Daemon ←→ tmux pipe-pane / send-keys
```

1. Mac sends `terminal.attach { thread_id, preset_name }` over WebSocket
2. Daemon attaches to the tmux pane programmatically and begins relaying output
3. Terminal data flows as binary WebSocket frames:
   - `terminal.output { thread_id, preset, data }` (daemon → mac)
   - `terminal.input  { thread_id, preset, data }` (mac → daemon)
   - `terminal.resize { thread_id, preset, cols, rows }` (mac → daemon)
4. SwiftTerm renders the byte stream via a custom `TerminalViewDelegate`
5. On disconnect/reconnect, daemon replays recent scrollback from tmux capture-pane

Benefits:
- Single connection — atomic reconnect, no partial failures
- Terminals are persistent (tmux survives everything)
- Multiple clients can view the same session (agents, phone via SSH, another Mac)
- No per-tab PTY management

## Beast Daemon (Rust)

### Responsibilities

1. **Git operations**: worktree create/remove, fetch, status, diff, commit — all local (no NFS)
2. **tmux orchestration**: create/destroy sessions, manage windows per preset
3. **Terminal I/O relay**: bridge tmux panes to WebSocket for Mac terminal views
4. **Hook execution**: run setup/teardown scripts defined in `.threadmill.yml`
5. **Process monitoring**: track which preset commands are running, report health
6. **Event push**: notify Mac app of state changes (process died, git status changed)
7. **State management**: persist thread metadata, reconcile with tmux/filesystem on startup
8. **Project management**: register repos, clone new ones, read `.threadmill.yml`

### Supervision

Managed by systemd:
```bash
systemctl --user enable --now threadmill-daemon
```

### WebSocket Protocol (JSON-RPC 2.0)

Bidirectional communication over SSH tunnel. Uses JSON-RPC 2.0 for request/response correlation. Binary frames for terminal I/O.

**Commands (Mac → Daemon):**
```jsonc
// Project management
{ "id": 1, "method": "project.list" }
{ "id": 2, "method": "project.add", "params": { "path": "/home/wsl/dev/myautonomy" } }
{ "id": 3, "method": "project.clone", "params": { "url": "git@github.com:...", "path": "/home/wsl/dev/newproject" } }
{ "id": 4, "method": "project.remove", "params": { "project_id": "..." } }
{ "id": 5, "method": "project.branches", "params": { "project_id": "..." } }
{ "id": 6, "method": "project.browse", "params": { "path": "/home/wsl/dev" } }  // list dirs on beast for project picker
{ "id": 7, "method": "thread.open_editor", "params": { "thread_id": "..." } }   // returns editor URI

// Thread lifecycle
{ "id": 10, "method": "thread.create", "params": { "project_id": "...", "name": "feature-x", "source_type": "new_feature" } }
{ "id": 11, "method": "thread.close", "params": { "thread_id": "...", "mode": "close" } }
{ "id": 12, "method": "thread.reopen", "params": { "thread_id": "..." } }
{ "id": 13, "method": "thread.list", "params": { "project_id": "..." } }  // optional filter
{ "id": 14, "method": "thread.cancel", "params": { "thread_id": "..." } }

// Terminal I/O (binary frames preferred for data, JSON for control)
{ "id": 20, "method": "terminal.attach", "params": { "thread_id": "...", "preset": "dev-server" } }
{ "id": 21, "method": "terminal.detach", "params": { "thread_id": "...", "preset": "dev-server" } }
{ "id": 22, "method": "terminal.resize", "params": { "thread_id": "...", "preset": "dev-server", "cols": 120, "rows": 40 } }

// Preset management
{ "id": 30, "method": "preset.start", "params": { "thread_id": "...", "preset": "dev-server" } }
{ "id": 31, "method": "preset.stop", "params": { "thread_id": "...", "preset": "dev-server" } }
{ "id": 32, "method": "preset.restart", "params": { "thread_id": "...", "preset": "dev-server" } }

// Connection health
{ "id": 99, "method": "ping" }
```

**Events (Daemon → Mac, no id):**
```jsonc
{ "method": "thread.progress", "params": { "thread_id": "...", "step": "running_hooks", "message": "bun install...", "error": null } }
{ "method": "thread.status_changed", "params": { "thread_id": "...", "old": "creating", "new": "active" } }
{ "method": "preset.process_event", "params": { "thread_id": "...", "preset": "dev-server", "event": "crashed", "exit_code": 1 } }

```

**Error responses:**
```jsonc
{ "id": 10, "error": { "code": -1, "message": "branch 'feature-x' already exists" } }
```

**Backpressure**: max 32 in-flight requests per connection (semaphore). Events are broadcast to all connected clients via `tokio::sync::broadcast`.

### Auth

- **Over SSH tunnel**: no additional auth needed (SSH provides identity)
- **Local access on beast** (`threadmill-cli`): shared secret in `~/.config/threadmill/auth_token`, sent as first message on connect

### State Model

Daemon persists thread metadata in `~/.config/threadmill/threads.json`:
```jsonc
{
  "threads": [
    {
      "id": "uuid",
      "project_id": "uuid",
      "name": "bridge-test-integration",
      "branch": "bridge-test-integration",
      "worktree_path": "/home/wsl/dev/.threadmill/myautonomy/bridge-test-integration",
      "status": "active",
      "source_type": "new_feature",
      "created_at": "2026-02-20T10:00:00Z"
    }
  ],
  "projects": [
    {
      "id": "uuid",
      "name": "myautonomy",
      "path": "/home/wsl/dev/myautonomy",
      "default_branch": "main"
    }
  ]
}
```

On startup, the daemon reconciles `threads.json` against reality:
- tmux session exists + worktree exists → `active` (keep)
- tmux session missing + worktree exists + status was `active` → crashed, restart tmux session
- tmux session missing + worktree exists + status was `hidden` → keep as `hidden`
- tmux session exists + worktree missing → orphan, kill tmux session, mark `failed`
- thread in JSON but worktree deleted externally → mark `closed`, remove from JSON

### Sync Protocol

On WebSocket connect:
1. Mac calls `thread.list` and `project.list`
2. Daemon returns authoritative state
3. Mac replaces local GRDB cache with daemon state
4. Mac subscribes to events for live updates

Daemon truth always wins. GRDB is a rendering cache.

### tmux Naming Convention

```
Session: tm_<project-id-short>_<sanitized-thread-name>
Window:  <preset-name>
```

Thread/project names are sanitized: colons, periods, spaces → hyphens. IDs used in session names to avoid collisions. Short IDs (first 8 chars of UUID).

### Worktree Layout

```
/home/wsl/dev/                          # project repos (clones)
├── myautonomy/                         # main worktree
├── tigerdata/
└── .threadmill/                        # managed worktrees
    ├── myautonomy/
    │   ├── bridge-test-integration/    # thread worktree
    │   └── fix-auth/
    └── tigerdata/
        └── dbt-refactor/
```

### tmux Session Layout

```
tmux session: tm_a1b2c3d4_bridge-test-integration
├── window 0: "dev-server"     → runs `task dev:worktree`
├── window 1: "opencode"       → runs `opencode`
└── window 2: "terminal"       → plain shell in worktree dir
```

Windows are created from terminal presets. Each preset = one tmux window. Parallel commands within a preset = split panes within that window.

## Project Config (.threadmill.yml)

Lives in the project repo root. Committed and versioned.

```yaml
# .threadmill.yml
setup:
  # Runs after worktree creation + copy_from_main, before presets start
  - bun install
  - task db:branch:sync

teardown:
  # Runs before worktree deletion
  - task db:branch:delete

copy_from_main:
  # Files/dirs copied from main worktree to new thread worktree
  - .env.local
  - .env.development.local

presets:
  dev-server:
    label: "Dev Server"
    commands:
      - task dev:worktree
    autostart: true

  dev-full:
    label: "Dev (Full Stack)"
    commands:
      - task dev:worktree
      - bun run storybook
    parallel: true      # each command gets its own pane
    autostart: false

  opencode:
    label: "OpenCode"
    commands:
      - opencode
    autostart: false

  terminal:
    label: "Terminal"
    commands:
      - $SHELL
    autostart: true
```

### Global Hooks

Global hooks (run for all projects) are defined in the daemon config:

```yaml
# ~/.config/threadmill/config.yml (on beast)
global_hooks:
  post_create:
    - echo "Thread created: $THREADMILL_THREAD"
  pre_delete:
    - echo "Thread closing: $THREADMILL_THREAD"

# Environment variables available in hooks and preset commands:
# THREADMILL_PROJECT      - project name
# THREADMILL_THREAD       - thread name
# THREADMILL_BRANCH       - git branch
# THREADMILL_WORKTREE     - worktree absolute path
# THREADMILL_MAIN         - main worktree absolute path
# THREADMILL_PORT_OFFSET  - per-thread port offset for dev servers
```

### Port Management

Each thread gets a port offset to avoid conflicts when running multiple dev servers:

```yaml
# .threadmill.yml
ports:
  base: 3000        # base port for dev server
  offset: 20        # each thread gets base + (thread_index * offset)
```

Daemon exposes `$THREADMILL_PORT_OFFSET` (0, 20, 40, ...) and `$THREADMILL_PORT_BASE` (3000, 3020, 3040, ...) as env vars in tmux sessions.

## Connection & Transport

```
Mac app ──SSH tunnel──► beast:19990 (daemon WebSocket)
         (single connection, multiplexed terminal I/O + RPC + events)
```

The SSH tunnel is managed by the app. The daemon listens on `127.0.0.1:19990` (localhost only).

### Connection State Machine

```
disconnected → connecting → authenticating → connected → reconnecting → ...
                                                ↓
                                           disconnected (if max retries exceeded)
```

- Auto-reconnect on tunnel drop with exponential backoff
- Queue commands during reconnection, fail after timeout
- On reconnect: full state sync (thread.list + project.list)
- Ping every 30s to detect dead tunnels

### SSH Tunnel Management

Shell out to `ssh` (inherits user's SSH config, agent, ProxyJump). Managed as a child process:
```bash
ssh -N -L 19990:127.0.0.1:19990 beast
```

App monitors the process, restarts on exit.

### External Agent Access

AI agents (OpenCode, Claude Code) running on beast can interact with threads:
- **tmux**: `tmux attach -t tm_a1b2c3d4_feature-x:opencode` — direct terminal access
- **CLI**: `threadmill-cli thread list`, `threadmill-cli thread create myautonomy feature-x` — talks to daemon WebSocket locally on beast
- **Discovery**: agents find their thread context from `$THREADMILL_THREAD` env var set in tmux sessions

## Technology Choices

| Component | Choice | Rationale |
|---|---|---|
| Mac UI | SwiftUI | Modern Apple framework, declarative, sidebar+detail layout |
| Mac persistence | GRDB | Mature SQLite wrapper, predictable concurrency model, cache of daemon state |
| Mac terminal | SwiftTerm | Mature Swift terminal emulator, custom `TerminalViewDelegate` for WebSocket I/O |
| Mac ↔ beast | SSH tunnel + WebSocket | Single multiplexed connection for RPC, events, and terminal I/O |
| Protocol | JSON-RPC 2.0 + binary frames | Request IDs, error codes, batching. Binary frames for terminal data. |
| Beast daemon | Rust + tokio | Fast, reliable, `tokio-tungstenite` for WebSocket, systemd-managed |
| Beast persistence | `threads.json` + tmux | Thin JSON for metadata, tmux for session persistence, reconciled on startup |
| Beast git | CLI (local) | Git runs natively on beast, no NFS, no wrapper needed |
| Project config | YAML in repo | Versioned, shared with team, readable |

## What This Eliminates

From the current Superset + WSL setup, Threadmill removes:
- `~/.superset/bin/git` wrapper (git is local on beast)
- NFS worktree checkout issues (worktrees created on beast natively)
- LSEnvironment / Info.plist patching (no Electron, no PATH discovery issues)
- `wsl-run` (daemon runs commands directly)
- `beast-port` / `beast-tunnel` workarounds (single SSH tunnel built into app)
- `ensure-superset-env` LaunchAgent (no longer needed)
- All path mapping logic (remote↔local) in the git wrapper

## Known Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| SwiftTerm ↔ WebSocket adapter is uncharted territory | High | Prototype in M1 before building anything else. Go/no-go gate. |
| tmux resize with multiple viewers at different sizes | Medium | `set -g window-size latest` — tmux uses most recent client's size |
| `.threadmill.yml` in malicious PR runs arbitrary commands | Medium | Trust-on-first-use: warn on new/changed hooks, require confirmation |
| Hidden threads accumulate disk usage | Low | Show disk usage in sidebar, optional auto-cleanup TTL in config |

## MVP Milestones

### M0: Connection (go/no-go gate)
- [ ] SSH tunnel establishment from Swift (shell out to `ssh`, process management)
- [ ] WebSocket client over tunnel with JSON-RPC 2.0
- [ ] Connection state machine (connect/reconnect/disconnect)
- [ ] Daemon scaffolding: WebSocket server, `ping`, systemd unit
- [ ] **SwiftTerm proof-of-concept**: one terminal view rendering tmux pane output via WebSocket relay. If this doesn't work well, reconsider the approach before investing further.

### M1: Projects & Threads
- [ ] `project.add` / `project.clone` / `project.list` / `project.remove`
- [ ] `thread.create` with progress streaming and cancellation
- [ ] `thread.close` / `thread.hide` / `thread.reopen`
- [ ] `threads.json` persistence + startup reconciliation
- [ ] GRDB cache on Mac, sync protocol on connect
- [ ] SwiftUI sidebar with projects and threads

### M2: Terminals & Presets
- [ ] Terminal I/O relay through WebSocket (attach/detach/resize)
- [ ] Multiple terminal tabs per thread (one per preset)
- [ ] Preset start/stop/restart
- [ ] Process status indicators (running/stopped/crashed)
- [ ] Scrollback replay on reconnect via `tmux capture-pane`

### M3: Lifecycle & Hooks
- [ ] `.threadmill.yml` parsing and validation
- [ ] Setup/teardown hook execution with progress reporting
- [ ] `copy_from_main` support
- [ ] Thread from existing branch
- [ ] Thread from PR URL
- [ ] Port management (offset allocation)
- [ ] `threadmill-cli` for beast-side agent access
- [ ] Keyboard shortcuts

### Post-MVP
- [ ] Menu bar quick access
- [ ] Notifications (process crashed, hook failed)
- [ ] Hidden thread TTL / disk usage visibility

### Non-goals
- **Git diff/commit UI** — use VS Code Remote SSH, GitHub Desktop, or neovim (fugitive/diffview) in a terminal preset. Threadmill manages threads, not git.
