# Threadmill Vision

## Purpose

Threadmill replaces Superset with a native macOS visor over a beast-hosted runtime:

- no NFS dependency for core operations
- no Electron environment fragility
- explicit project/thread/preset model with tmux persistence

## Current Product Shape

Everything below is split into implemented vs planned.

## Key Features

### 1) Projects

- [x] Add existing beast repo (`project.add`)
- [x] Clone repo from URL (`project.clone`)
- [x] List/remove projects (`project.list`, `project.remove`)
- [x] Parse `.threadmill.yml` and expose project presets

### 2) Threads

- [x] Thread = project + worktree + branch + tmux session
- [x] Create from new feature branch
- [x] Create from existing branch path
- [x] Hide thread (keep worktree) and reopen
- [x] Close thread (teardown + worktree removal)
- [x] Cancel in-flight thread creation (`thread.cancel`)
- [x] PR URL → branch extraction and thread creation

### 3) Terminal Presets

- [x] Presets render as tabs in thread view
- [x] Presets map to tmux windows
- [x] Start/stop/restart over RPC
- [x] Process events streamed (`preset.process_event`)

Current preset format:

```yaml
presets:
  dev-server:
    command: task dev:worktree
  opencode:
    command: opencode
  terminal:
    command: $SHELL
```

Optional `cwd` is supported for presets.

### 4) Setup / Teardown and File Copy

- [x] `setup` hooks run during thread creation
- [x] `teardown` hooks run during close
- [x] `copy_from_main` supports bootstrapping files like `.env.local`

### 5) AI Agent Awareness

- [x] Agent sessions can run as normal presets (agent-agnostic)
- [x] tmux sessions include thread context env vars
- [x] `threadmill-cli` is available for agent-side automation
- [x] `threadmill-cli thread info` resolves context from `THREADMILL_THREAD`

### 6) Port Management

- [x] Per-project port offsets are allocated and persisted
- [x] `.threadmill.yml` supports:

```yaml
ports:
  base: 3000
  offset: 20
```

- [x] tmux/hook env receives `THREADMILL_PORT_OFFSET` and `THREADMILL_PORT_BASE`

### 7) Transport and Persistence

- [x] Single SSH tunnel + single WebSocket for RPC/events/terminal data
- [x] tmux persistence survives app disconnects and daemon restarts
- [x] Daemon state persisted in `threads.json` and reconciled at startup
- [x] Scrollback replay on reconnect via `tmux capture-pane`

### 8) Keyboard Shortcuts

- [x] Cmd+1..9 select thread by index
- [x] Cmd+T new thread sheet
- [x] Cmd+W close selected thread
- [x] Cmd+]/[ next/prev preset tab
- [x] Cmd+Shift+R restart current preset
- [x] Cmd+Shift+K toggle connection

## Architecture Split

- **Threadmill (macOS)**: UI, selection state, local GRDB cache, terminal surface hosting
- **Spindle (beast)**: JSON-RPC server, git/tmux orchestration, state persistence, hook execution
- **Protocol**: shared JSON-RPC schema + runtime events
- **threadmill-cli (beast)**: local command interface to daemon WebSocket

## Milestone Status

### M0
- [x] Connection and transport foundation
- [x] Terminal rendering and relay pipeline

### M1
- [x] Projects CRUD and clone
- [x] Threads lifecycle core (create/hide/reopen/close)
- [x] Persistent daemon state + app sync cache
- [x] Create cancellation

### M2
- [x] Preset tabs and controls
- [x] Terminal attach/detach/resize RPC path
- [x] Preset process event stream
- [x] Reconnect scrollback replay

### M3
- [x] `.threadmill.yml` parsing in daemon
- [x] setup/teardown/copy_from_main
- [x] Port offset model and env wiring
- [x] `threadmill-cli`
- [x] PR URL to branch flow in app UX
- [x] Keyboard shortcut coverage

## Non-Goals

- Git diff/commit UI in Threadmill
- Generic multi-host orchestration
- Generic SSH abstraction layer
- Trust UX for hook review (unnecessary for single-user)
