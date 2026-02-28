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

- [x] Presets render as terminal sessions in thread view
- [x] Presets map to tmux windows
- [x] Start/stop/restart over RPC
- [x] Process events streamed (`preset.process_event`)
- [x] Multi-session terminals (ZStack keep-alive, tab switching preserves state)

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
- [x] Pre-registration frame buffering (binary frames before attach response)

### 8) Mode Switcher (aizen-inspired)

- [x] Segmented picker: Chat / Terminal / Files / Browser
- [x] Icons + labels in each segment (message, terminal, folder, globe)
- [x] @AppStorage visibility toggles per mode
- [x] Keyboard shortcuts: ⌘1-4 (by visible index), ⌃Tab/⌃⇧Tab (cycle)
- [x] Hidden title bar + unified toolbar style
- [x] Per-thread mode + session state persistence

### 9) Session Tabs

- [x] Capsule-styled horizontal session tabs in toolbar
- [x] Navigation arrows (chevron.left/right) with bounce effect
- [x] "+" button with Menu/primaryAction for preset/agent picker
- [x] Close button (xmark.circle.fill) inside each tab
- [x] Context menus: Close, Close All Left/Right, Close Others
- [x] Mouse wheel vertical→horizontal scroll conversion
- [x] Thread-scoped preset APIs (race-safe across thread switches)

### 10) Chat (opencode serve)

- [x] Multi-conversation per thread (GRDB-persisted)
- [x] opencode serve HTTP API integration
- [x] Thinking/COT display
- [x] Enter=send, Shift+Enter=newline
- [x] Session tabs for multiple conversations
- [x] Stale session guards on thread switch

### 11) Browser

- [x] WKWebView with internal tab bar
- [x] GRDB-persisted browser sessions per thread
- [x] URL bar, back/forward/reload, loading progress
- [x] Safari user-agent, JS enabled, developer extras, isInspectable
- [x] Default URL: localhost + port offset (dev server)
- [x] New-tab requests (target=_blank) handled

### 12) File Browser

- [x] HSplitView: tree sidebar (30%) + content viewer (70%)
- [x] Spindle RPCs: file.list, file.read, file.git_status
- [x] Recursive directory tree with lazy loading
- [x] File type icons (SF Symbol-based, extension-mapped)
- [x] Git status coloring (yellow=modified, green=added, blue=untracked, red=deleted)
- [x] Syntax highlighting (regex-based, Catppuccin palette)
- [x] Line number gutter
- [x] File tabs with shared TabContainer/TabLabel/TabCloseButton
- [x] Sidebar toggle, nav arrows for file tabs
- [x] Path authorization + TOCTOU hardening in Spindle
- [x] Error states with retry actions

### 13) Keyboard Shortcuts

- [x] ⌘1..4 select mode by visible index
- [x] ⌃Tab/⌃⇧Tab cycle modes
- [x] ⌘T new thread sheet
- [x] ⌘W close selected thread

## Architecture Split

- **Threadmill (macOS)**: UI, selection state, local GRDB cache, terminal surface hosting, browser, file viewer
- **Spindle (beast)**: JSON-RPC server, git/tmux orchestration, state persistence, hook execution, file service
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

### M4
- [x] Mode switcher (chat/terminal/files/browser)
- [x] Multi-session tabs (capsule-styled, aizen-inspired)
- [x] Terminal multi-session (ZStack keep-alive)
- [x] Chat multi-session (GRDB + opencode serve)
- [x] Per-thread tab state persistence

### M5
- [x] Browser view (WKWebView + GRDB sessions)
- [x] File browser (Spindle RPCs + tree + syntax highlighting)
- [x] file.list / file.read / file.git_status RPCs
- [x] Git status coloring in file tree

## Non-Goals

- Git diff/commit UI in Threadmill
- Generic multi-host orchestration
- Generic SSH abstraction layer
- Trust UX for hook review (unnecessary for single-user)
