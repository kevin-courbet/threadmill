# Threadmill Architecture

## Reality Check

This document describes what is implemented today across:
- **Threadmill** (macOS Swift app)
- **Spindle** (Rust daemon on beast)
- **threadmill-cli** (Rust CLI on beast)

Planned work is explicitly marked as **Planned**.

## Overview

Threadmill is a native macOS visor for development workspaces that run on beast (WSL2).

- The app uses one SSH tunnel and one WebSocket connection.
- Spindle owns source-of-truth state and executes git/tmux/process work.
- The Mac app caches daemon state in SQLite (GRDB) for rendering.

## Core Concepts

### Project

A registered git repo on beast.

- Added via `project.add` (existing path) or `project.clone` (git URL).
- Persisted in Spindle state (`threads.json`) with `id`, `name`, `path`, `default_branch`.
- Includes parsed presets from `.threadmill.yml` (or daemon defaults if missing/invalid).

### Thread

A managed work context for a project.

- Backed by git worktree + tmux session + persisted metadata.
- Lifecycle: `creating -> active -> closing -> closed | hidden | failed`.
- Includes `port_offset` for deterministic port allocation.

### Preset

A named terminal workflow.

- Mapped to tmux windows.
- Started/stopped/restarted over RPC.
- Parsed from `.threadmill.yml` with `command` (current canonical format) and optional `cwd`.

### Mode

The detail view's active tab. One of: `chat`, `terminal`, `files`, `browser`.

- Persisted per thread via `ThreadTabStateManager` (@AppStorage JSON).
- Each mode has independent session selection.

## System Architecture

```
macOS (Threadmill)                              beast / WSL2 (Spindle)
-------------------                              -----------------------
SwiftUI + AppKit                                Rust daemon (tokio)
GRDB cache                                      state_store (threads.json)
GhosttyKit terminal surface                     git + tmux orchestration
ACP agent session manager                       agent process relay (stdin/stdout)
WKWebView browser                               file service (list/read/git_status)
WebSocket client                                WebSocket server

           single SSH tunnel + single WebSocket connection
```

All JSON-RPC requests, daemon events, and terminal binary frames share this single WebSocket.

## UI Architecture

### Mode Switcher

Segmented `Picker` in toolbar with four modes:
- **Chat**: ACP agent conversations via binary WebSocket relay
- **Terminal**: remote terminals via Spindle pipe-pane relay
- **Files**: remote file browser via Spindle file.list/read/git_status RPCs
- **Browser**: WKWebView tabs for dev servers (localhost + port offset)

Tab visibility controlled by `@AppStorage` booleans. Keyboard shortcuts: ⌘1-4 (by visible index), ⌃Tab/⌃⇧Tab (cycle).

### Session Tabs

Each mode (chat, terminal) has a horizontal session tab bar in the toolbar. Capsule-styled buttons with close (xmark), nav arrows, and "+" with Menu/primaryAction for preset/agent picker. Context menus: Close, Close All Left/Right, Close Others.

### Terminal Multi-Session

All terminal sessions kept alive in ZStack with opacity/allowsHitTesting toggle. No recreation on tab switch — preserves terminal state.

### Chat Multi-Session

`ChatConversation` records persisted in GRDB per thread. Each conversation maps to an ACP agent session (via `agentSessionID` + `agentType`). Multiple conversations shown as session tabs. `ChatSessionViewModel` subscribes to `AgentSessionManager` notifications and builds a structured timeline (messages, tool calls, tool call groups, turn summaries).

### Browser

WKWebView with internal tab bar (separate from mode session tabs). BrowserSession persisted in GRDB. URL bar, back/forward/reload, loading progress. Default URL: `localhost:{3000 + portOffset}`.

### File Browser

HStack split layout: tree sidebar + content viewer. Tree loaded via `file.list` RPC. Files opened via `file.read` RPC. Content rendered with CodeEditSourceEditor (tree-sitter highlighting via CodeEditLanguages queries), gutter line numbers, and monospaced font. Git status coloring via `file.git_status` RPC.

## Supervision (Implemented)

Spindle runs as a **systemd user service**:

`~/.config/systemd/user/spindle.service`

- `ExecStart=/home/wsl/dev/spindle/target/debug/spindle`
- `Restart=on-failure`
- `RestartSec=2`
- `WantedBy=default.target`

Operational commands are exposed in `Taskfile.yml`:

- `task spindle:restart`
- `task spindle:status`
- `task spindle:logs`

## RPC and Event Protocol (Implemented)

JSON-RPC 2.0 methods currently routed by `rpc_router.rs`:

- `ping`
- `state.snapshot`
- `project.list`, `project.add`, `project.clone`, `project.remove`, `project.branches`, `project.browse`
- `thread.create`, `thread.list`, `thread.close`, `thread.reopen`, `thread.hide`
- `terminal.attach`, `terminal.detach`, `terminal.resize`
- `preset.start`, `preset.stop`, `preset.restart`
- `agent.start`, `agent.stop`
- `file.list`, `file.read`, `file.git_status`

Daemon events currently emitted:

- `thread.progress`
- `thread.status_changed`
- `thread.created`
- `project.added`
- `project.removed`
- `state.delta`
- `preset.process_event`
- `agent.status_changed`
- `project.clone_progress`

Defined but not currently emitted by daemon:

- `thread.removed` (reserved)

Terminal binary frames use channel multiplexing:

`[u16 channel_id][raw bytes...]`

## Auth (Current State)

There is currently **no enforced daemon auth layer** on localhost WebSocket access.

- Daemon is expected to listen on localhost and usually be reached via SSH tunnel from macOS.
- `threadmill-cli` can include `auth_token` if `~/.config/threadmill/auth_token` exists, but current daemon routing does not enforce it.

## State Model

Spindle persists state in:

`~/.config/threadmill/threads.json`

Thread entries include:

- `id`, `project_id`, `name`, `branch`, `worktree_path`
- `status`, `source_type`, `created_at`, `tmux_session`
- `port_offset`

On startup, Spindle reconciles persisted state against:

- worktree existence
- tmux session existence

and repairs status / sessions where possible.

## Data Model (Threadmill GRDB Cache)

### Project model

`Sources/Threadmill/Models/Project.swift`:

- `id`
- `name`
- `remotePath`
- `defaultBranch`
- `presets` (`presets_json` column)

Preset entries contain:

- `name`
- `command`
- `cwd` (optional)

### Thread model

`Sources/Threadmill/Models/Thread.swift`:

- `id`, `projectId`, `name`, `branch`, `worktreePath`
- `status`, `sourceType`, `createdAt`, `tmuxSession`
- `portOffset` (`port_offset` column)

### AgentConfig model

`Sources/Threadmill/Models/AgentConfig.swift`:

- `name`, `command`, `cwd` (optional)
- Parsed from `.threadmill.yml` `agents` section
- Returned in `project.list` response

### ChatConversation model

`Sources/Threadmill/Models/ChatConversation.swift`:

- `id` (UUID), `threadID`, `agentSessionID` (nullable), `agentType`
- `title`, `createdAt`, `updatedAt`
- `isArchived`

### BrowserSession model

`Sources/Threadmill/Models/BrowserSession.swift`:

- `id` (UUID), `threadID`
- `url`, `title`, `order`
- `createdAt`

### GRDB Migrations

- v1: base tables (project, thread)
- v2: presets column
- v3: port_offset column
- v4: chat_conversation table
- v5: browser_session table
- v6: remote model (remotes table + project.remote_id FK)
- v7: repo model (repos table + project.repo_id FK)
- v8: remote default flag (is_default unique constraint)
- v9: project agents column (agents_json)
- v10: chat_conversation agent session (opencodeSessionID -> agentSessionID + agentType)

## Project Config (`.threadmill.yml`)

Spindle actively parses `.threadmill.yml`.

Current implemented fields:

```yaml
setup:
  - bun install

teardown:
  - task db:branch:delete

copy_from_main:
  - .env.local

ports:
  base: 3000
  offset: 20

presets:
  dev-server:
    command: task dev:worktree
    cwd: .

agents:
  opencode:
    command: opencode
    cwd: .
```

Notes:

- `ports.offset` must be `> 0`.
- If no config exists, project presets from `project.list` default to `editor` (`$EDITOR` or `nvim`) and `shell` (`$SHELL` or `bash`).
- During thread creation, fallback lifecycle config adds a `terminal` preset for autostart/lifecycle handling.
- Preset lifecycle flags (`autostart`, `parallel`) are still read from thread config where defined.

## Port Management (Implemented)

Per-project deterministic allocation:

1. Read `ports.offset` (default `20`).
2. Collect used offsets for that project from non-closed/non-failed threads.
3. Allocate first free offset in sequence: `0, 20, 40, ...`.
4. Compute port base with `ports.base + port_offset`.

Example with `base: 3000`, `offset: 20`:

- thread A -> `THREADMILL_PORT_OFFSET=0`, `THREADMILL_PORT_BASE=3000`
- thread B -> `THREADMILL_PORT_OFFSET=20`, `THREADMILL_PORT_BASE=3020`

## Thread Environment Variables (Implemented)

Spindle injects these into tmux sessions and hook execution:

- `THREADMILL_PROJECT`
- `THREADMILL_THREAD`
- `THREADMILL_BRANCH`
- `THREADMILL_WORKTREE`
- `THREADMILL_MAIN`
- `THREADMILL_PORT_OFFSET`
- `THREADMILL_PORT_BASE`

## External Agent Access (Implemented)

Agents on beast can use tmux directly or `threadmill-cli`.

CLI commands implemented in `src/bin/threadmill-cli.rs`:

- `threadmill-cli status [--pretty]`
- `threadmill-cli project list [--pretty]`
- `threadmill-cli thread list [--project <id|name>] [--pretty]`
- `threadmill-cli thread create <project-id|project-name> <name> [--branch <branch>] [--pretty]`
- `threadmill-cli thread close <thread-id> [--pretty]`
- `threadmill-cli thread info [--pretty]` (uses `THREADMILL_THREAD` env)

Default endpoint is `ws://127.0.0.1:19990` and can be overridden with `THREADMILL_CLI_WS_URL`.

## Technology Choices (Current)

| Component | Choice |
|---|---|
| Mac app | Swift + SwiftUI + AppKit |
| Mac cache | GRDB / SQLite |
| Terminal rendering | GhosttyKit (libghostty) |
| Browser rendering | WKWebView |
| Syntax highlighting | tree-sitter via CodeEditSourceEditor (files + chat code blocks) |
| Transport | SSH tunnel + WebSocket |
| Protocol | JSON-RPC 2.0 + binary frames |
| Daemon runtime | Rust + tokio + tokio-tungstenite |
| Daemon persistence | JSON state store (`threads.json`) + tmux |
| Config parsing | `serde_yaml` |
| CLI | `clap` + `threadmill-cli` binary |

## Milestone Status

### M0: Connection + Terminal Feasibility
- [x] SSH tunnel management from app
- [x] WebSocket JSON-RPC transport
- [x] Reconnect state machine
- [x] Daemon ping + terminal attach/detach/resize
- [x] End-to-end terminal relay over single connection
- [x] GhosttyKit integration
- [x] PTY shim relay path used for remote terminal rendering

### M1: Projects and Threads
- [x] `project.add` / `project.clone` / `project.list` / `project.remove`
- [x] `thread.create` with progress streaming
- [ ] `thread.create` cancellation (`thread.cancel`)
- [x] `thread.close` / `thread.hide` / `thread.reopen`
- [x] `threads.json` persistence + reconciliation
- [x] GRDB cache + sync-from-daemon model
- [x] Project/thread sidebar model in app state

### M2: Terminals and Presets
- [x] Terminal I/O relay (`terminal.attach` / `detach` / `resize`)
- [x] Multiple preset tabs per thread
- [x] `preset.start` / `preset.stop` / `preset.restart`
- [x] Preset process event stream (`preset.process_event`)
- [x] Scrollback replay on reconnect via `tmux capture-pane`
- [x] Pre-registration frame buffering for scrollback race

### M3: Lifecycle and Hooks
- [x] `.threadmill.yml` parsing
- [x] setup/teardown hooks
- [x] `copy_from_main`
- [x] Existing branch thread creation path
- [ ] PR URL -> branch extraction workflow
- [x] Port offset management
- [x] `threadmill-cli`
- [x] Keyboard shortcut coverage

### M4: Mode Switcher + Multi-Session UI
- [x] Segmented mode picker (chat/terminal/files/browser) with icons
- [x] Session tabs in toolbar (capsule-styled, context menus, nav arrows)
- [x] Terminal multi-session (ZStack keep-alive)
- [x] Chat multi-session (GRDB conversations + opencode serve)
- [x] Per-thread tab state persistence (@AppStorage JSON)
- [x] Hidden title bar + unified toolbar
- [x] WheelScrollHandler for tab bar horizontal scroll
- [x] Menu + primaryAction "+" button for preset picker

### M5: Browser + File Browser
- [x] WKWebView browser with internal tab bar
- [x] Browser session GRDB persistence
- [x] URL bar, back/forward/reload, loading progress
- [x] File browser: tree + content viewer (HStack split layout)
- [x] `file.list` RPC with path authorization + TOCTOU hardening
- [x] `file.read` RPC (5MB cap, UTF-8 only)
- [x] `file.git_status` RPC (porcelain v1 parsing)
- [x] Syntax highlighting (tree-sitter via CodeEditSourceEditor + CodeEditLanguages)
- [x] SourceEditor gutter line numbers
- [x] File type icons (SF Symbol-based)
- [x] Git status coloring in file tree

### M6: ACP Agent Chat
- [x] ACP transport layer (`AgentSessionManager`, binary frame relay)
- [x] `agent.start` / `agent.stop` RPC + `agent.status_changed` event
- [x] `.threadmill.yml` agents section + `AgentConfig` in project model
- [x] `ChatSessionViewModel` with ACP streaming + timeline building
- [x] Rich chat UI: tool call accordions, grouped tools, turn summaries, markdown, code blocks
- [x] Animated gradient border, shimmer thinking, streaming perf coalescing
- [x] Agent/mode/model selectors in chat input bar
- [x] Reconnect-safe agent session lifecycle

### Planned (Post-MVP)
- [ ] Menu bar quick actions
- [ ] User-facing notifications for crashes/failures
- [ ] Hidden-thread TTL and disk-usage controls
- [ ] Split terminal panes
- [ ] File search palette (Cmd+P)
- [ ] Command palette (Cmd+Shift+P)
