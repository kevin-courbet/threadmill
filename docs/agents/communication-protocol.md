---
updated: 2026-02-25
---

# Communication Protocol

## Overview

Threadmill (macOS) and Spindle (beast) communicate over a **single WebSocket connection** tunneled through SSH. All RPC calls, events, and terminal I/O share this one connection.

```
Threadmill (macOS)                          Spindle (beast/WSL2)
┌──────────────┐    SSH tunnel (-L)    ┌──────────────────┐
│ SwiftUI App  │ ◄──────────────────► │ Rust daemon       │
│ URLSession   │   ws://127.0.0.1     │ tokio-tungstenite │
│ WebSocket    │     :19990           │ WebSocket server  │
└──────────────┘                      └──────────────────┘
```

## Connection Lifecycle

```
App Launch
  │
  ├─ SSHTunnelManager.start()
  │    ssh -L 19990:127.0.0.1:19990 beast -N
  │    await port ready
  │
  ├─ WebSocketClient.connect(ws://127.0.0.1:19990)
  │    URLSessionWebSocketTask.resume()
  │    receiveNextMessage() loop starts immediately
  │    HTTP upgrade handshake completes async
  │
  ├─ request("ping") → "pong"
  │    state = .connected
  │
  ├─ SyncService.syncFromDaemon()
  │    request("project.list") → [Project]
  │    request("thread.list") → [Thread]
  │    populate GRDB cache + AppState
  │
  └─ Ready for user interaction
```

## Message Types

### 1. JSON-RPC 2.0 (text frames)

**Request** (Threadmill → Spindle):
```json
{"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}}
```

**Response** (Spindle → Threadmill):
```json
{"jsonrpc": "2.0", "id": 1, "result": "pong"}
```

**Event/Notification** (Spindle → Threadmill, no id):
```json
{"jsonrpc": "2.0", "method": "thread.status_changed", "params": {"thread_id": "...", "old": "creating", "new": "active"}}
```

### 2. Binary frames (terminal I/O)

```
[2 bytes: channel_id big-endian u16][N bytes: raw PTY data]
```

Channel 0 is reserved/invalid. Channel IDs are allocated by Spindle on `terminal.attach`.

## Terminal Attach Flow

```
User selects thread in sidebar
  │
  ├─ AppState.attachSelectedPreset()
  │    guard thread.status == .active
  │
  ├─ request("preset.start", {thread_id, preset})
  │    Spindle ensures tmux window exists for preset
  │
  ├─ TerminalMultiplexer.attach(threadID, preset)
  │    ├─ Create RelayEndpoint
  │    │    bind Unix socket at /tmp/threadmill-<pid>-<uuid>.sock
  │    │    listen for relay process connection
  │    │
  │    ├─ request("terminal.attach", {thread_id, preset})
  │    │    Spindle allocates channel_id, starts pipe-pane
  │    │    returns {channel_id: <u16>}
  │    │
  │    └─ Register endpoint in channel→endpoint map
  │
  ├─ GhosttyTerminalView mounts on NSView
  │    ghostty_surface_new(command: "threadmill-relay")
  │    relay connects to Unix socket
  │
  └─ Data flows:
       Input:  Ghostty keyDown → relay stdin → Unix socket → RelayEndpoint
               → prepend channel_id → WebSocket binary frame → Spindle
               → tmux send-keys (or persistent PTY writer)

       Output: Spindle tmux pipe-pane → binary frame [channel_id][data]
               → WebSocket → TerminalMultiplexer.dispatch(channel_id)
               → RelayEndpoint.handleBinaryFrame → Unix socket write
               → relay stdout → Ghostty renders via Metal
```

## Event Flow

```
Spindle emits event (e.g., thread created)
  │
  ├─ WebSocket text frame (no id = notification)
  │    {"method": "thread.created", "params": {...}}
  │
  ├─ WebSocketClient.handleJSONString()
  │    detects no "id" field → route to onEvent
  │
  ├─ ConnectionManager.onEvent → AppState.handleDaemonEvent()
  │    match on method name
  │
  └─ Action:
       thread.status_changed → update GRDB + AppState
       thread.created/removed → schedule sync
       project.added/removed → schedule sync
       state.delta → schedule sync (or apply inline)
       thread.progress → update status, cancel attach if failed
```

## Reconnect Flow

```
Transport drop detected (SSH dies, WebSocket closes)
  │
  ├─ ConnectionManager.handleTransportDrop()
  │    state = .disconnected
  │    stop ping loop
  │    disconnect WebSocket + SSH tunnel
  │
  ├─ scheduleReconnect() (exponential backoff, max 8 attempts)
  │    state = .reconnecting(attempt: N)
  │
  ├─ connect(initial: false)
  │    restart SSH tunnel → reconnect WebSocket → ping
  │
  ├─ state = .connected
  │
  ├─ TerminalMultiplexer.reattachAll()
  │    for each active attachment:
  │      terminal.attach → get new channel_id
  │      remap endpoint to new channel
  │      terminal.resize with stored dimensions
  │
  └─ SyncService.syncFromDaemon()
       re-fetch full state
```

## RPC Methods

| Method | Direction | Params | Result |
|--------|-----------|--------|--------|
| ping | → | {} | "pong" |
| project.add | → | {path} | {project} |
| project.list | → | {} | [Project] |
| project.remove | → | {project_id} | {} |
| project.branches | → | {project_id} | [string] |
| project.clone | → | {url, path?} | Project |
| thread.create | → | {project_id, name, branch?} | {thread} |
| thread.list | → | {} | [Thread] |
| thread.close | → | {thread_id} | {} |
| thread.hide | → | {thread_id} | {} |
| thread.reopen | → | {thread_id} | {} |
| terminal.attach | → | {thread_id, preset} | {channel_id} |
| terminal.detach | → | {thread_id, preset} | {} |
| terminal.resize | → | {thread_id, preset, cols, rows} | {} |
| preset.start | → | {thread_id, preset} | {ok} |
| preset.stop | → | {thread_id, preset} | {ok} |
| preset.restart | → | {thread_id, preset} | {ok} |
| state.snapshot | → | {} | {version, projects, threads} |

## Events (Spindle → Threadmill)

| Event | Params |
|-------|--------|
| thread.status_changed | {thread_id, old, new} |
| thread.progress | {thread_id, step, message, error?} |
| thread.created | {thread} |
| thread.removed | {thread_id} |
| project.added | {project} |
| project.removed | {project_id} |
| state.delta | {version, changes[]} |
| preset.process_event | {thread_id, preset, event, exit_code?} |

## Key Constraints

- **Single connection**: All RPC + events + terminal I/O multiplexed on one WebSocket
- **Daemon is truth**: GRDB on macOS is a cache; Spindle owns all state
- **Channel IDs are ephemeral**: Invalidated on disconnect, reallocated on reconnect
- **tmux survives everything**: Sessions persist across app quit, SSH drops, daemon restarts

## Operational Notes

- **Stale daemon**: After rebuilding Spindle (`task build:spindle`), the running daemon must be restarted. Use `task spindle:restart` or `task run` (which auto-restarts).
- **SSH multiplexing**: beast SSH uses ControlMaster. Stale sockets can block new connections. Reset with `beast-ssh-ensure --reset`.
- **Port 19990**: Hardcoded on both sides. SSH tunnel forwards localhost:19990 → beast:19990.
