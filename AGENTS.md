# Threadmill — Agent Conventions

## What This Is

Native macOS visor app (Swift/SwiftUI) managing dev "threads" (git worktrees + tmux sessions) on a remote Linux machine ("beast" via SSH). Paired with **Spindle**, a Rust daemon on beast. Single WebSocket over SSH tunnel for all RPC, events, and terminal I/O.

## Development Methodology: Red-Green-Refactor (TDD)

1. **Red** — Write a failing test describing the desired behavior. Run it; confirm it fails. No production code yet.
2. **Green** — Write minimum production code to make the test pass.
3. **Refactor** — Clean up. All tests must stay green.

### Rules

- Never skip Red. A test never seen failing proves nothing.
- One behavior per cycle. Multiple behaviors = multiple cycles.
- Commit at Green or after Refactor — never at Red.
- Bug found → reproduce with failing test first, then fix.

### Validation commands

| Command | What it does |
|---|---|
| `task test:swift` | Swift unit tests (must pass after every Green/Refactor) |
| `task test:spindle` | Spindle integration tests on beast via SSH |
| `task test:ui` | UI e2e tests (opt-in, requires Accessibility) |
| `task validate` | Full gate: `build:all` + `test` |
| `task run` | Build + restart Spindle + launch app |
| `task spindle:restart` | Rebuild + `systemctl --user restart spindle` |
| `task spindle:logs` | `journalctl --user -u spindle -f` |

---

## Architecture Overview

```
macOS (visor)                         beast (WSL2)
─────────────                         ────────────
Threadmill.app (SwiftUI)   ◄─ SSH tunnel + WS ─►   Spindle daemon (Rust/tokio)
├── GRDB (cache only)                               ├── WebSocket JSON-RPC server
├── GhosttyKit (Metal GPU terminal)                  ├── Git/tmux orchestration
├── WebSocket client                                 ├── .threadmill.yml config
└── PTY shim relay (threadmill-relay)                ├── threads.json state store
                                                     └── threadmill-cli (agent CLI)
```

**Daemon is truth.** GRDB on Mac is a rendering cache. On every connect, Mac syncs from daemon.

**Single WebSocket.** All JSON-RPC requests, events, and terminal binary frames share one connection over one SSH tunnel. No per-tab connections.

---

## Two Codebases

### Threadmill (this repo) — macOS Swift app

| Path | Purpose |
|---|---|
| `Package.swift` | SPM manifest (macOS 14+, GRDB, GhosttyKit xcframework) |
| `Taskfile.yml` | go-task runner for build/test/run/validate |
| `protocol/threadmill-rpc.schema.json` | JSON-RPC schema (source of truth for types) |
| **Sources/Threadmill/** | |
| `App/ThreadmillApp.swift` | SwiftUI @main entry, window config, dark mode |
| `App/AppDelegate.swift` | NSApplicationDelegateAdaptor, bootstrap connection + sync |
| `App/AppState.swift` | Central @Observable state — event handling, attach flow, thread/project actions |
| `Connection/WebSocketClient.swift` | URLSessionWebSocketTask JSON-RPC + binary frames |
| `Connection/SSHTunnelManager.swift` | SSH tunnel child process lifecycle |
| `Transport/ConnectionManager.swift` | Connection state machine, reconnect with backoff, DI-friendly |
| `Transport/TerminalMultiplexer.swift` | channel_id → RelayEndpoint dispatch |
| `Transport/RelayEndpoint.swift` | Per-terminal Unix socket + bounded frame buffer |
| `Terminal/GhosttySurfaceHost.swift` | ghostty_app lifecycle, surface registry, callbacks |
| `Terminal/GhosttyTerminalView.swift` | NSViewRepresentable, endpoint swap on thread switch |
| `Terminal/GhosttyNSView.swift` | Raw NSView for Metal surface hosting |
| `Database/DatabaseManager.swift` | GRDB setup + migrations (v1 base, v2 presets, v3 port_offset) |
| `Database/SyncService.swift` | project.list + thread.list sync from daemon |
| `Models/Project.swift` | Project + PresetConfig (includes presets from daemon) |
| `Models/Thread.swift` | ThreadModel with portOffset |
| `Models/Preset.swift` | Preset enum + defaults |
| `Models/ThreadStatus.swift` | Status enum (creating/active/closing/closed/hidden/failed) |
| `Support/Abstractions.swift` | DI protocols: ConnectionManaging, DatabaseManaging, etc. |
| `Features/Projects/SidebarView.swift` | Sidebar with project sections |
| `Features/Projects/ProjectSection.swift` | Per-project disclosure group + thread rows |
| `Features/Projects/AddProjectSheet.swift` | Open existing project on beast |
| `Features/Projects/CloneRepoSheet.swift` | Clone repo by URL |
| `Features/Threads/ThreadDetailView.swift` | Compact header + terminal view |
| `Features/Threads/ThreadRow.swift` | Sidebar row with status + branch |
| `Features/Threads/NewThreadSheet.swift` | Create thread with project preselection |
| `Features/TerminalTabs/TerminalTabBar.swift` | Preset tab bar (dynamic from project config) |
| `Features/TerminalTabs/TerminalTabView.swift` | Terminal or loading spinner |
| `Features/TerminalTabs/TerminalTabModel.swift` | Tab model with isAttached state |
| `Views/ContentView.swift` | NavigationSplitView, sidebar width |
| `Views/Components/ConnectionStatusView.swift` | Colored dot (green/yellow/red) |
| **Sources/threadmill-relay/** | |
| `main.c` | ~30-line C PTY bridge: stdin/stdout ↔ Unix socket |
| **Tests/ThreadmillTests/** | Unit tests with mock doubles |
| **Tests/ThreadmillUITests/** | UI e2e harness with MockSpindleServer (opt-in) |

### Spindle (on beast) — Rust daemon

Access via `ssh beast`. Code at `/home/wsl/dev/spindle/`.

| Path | Purpose |
|---|---|
| `src/main.rs` | Binary entry |
| `src/lib.rs` | WebSocket server, connection handling, event broadcast |
| `src/protocol.rs` | All RPC types, method constants, event payloads, params |
| `src/rpc_router.rs` | JSON-RPC method dispatch |
| `src/state_store.rs` | threads.json persistence, startup reconciliation, port offset tracking |
| `src/tmux.rs` | tmux command helpers |
| `src/services/project.rs` | project.add/list/remove/branches/clone + .threadmill.yml parsing |
| `src/services/thread.rs` | thread.create/close/hide/reopen/list + env var setup |
| `src/services/terminal.rs` | terminal.attach/detach/resize, channel allocation, pipe-pane relay |
| `src/services/preset.rs` | preset.start/stop/restart, process monitoring, config-driven commands |
| `src/bin/threadmill-cli.rs` | CLI for agent-side automation (clap) |
| `tests/` | Integration tests (project, thread, terminal, preset, sync, binary, CLI) |

### Spindle daemon management

Spindle runs as a **systemd user service** on beast:

```bash
ssh beast "systemctl --user status spindle"     # check status
ssh beast "systemctl --user restart spindle"     # restart after rebuild
ssh beast "journalctl --user -u spindle -f"      # tail logs
```

**CRITICAL**: After rebuilding Spindle, the daemon must be restarted. A stale daemon running a deleted binary causes silent failures. `task spindle:restart` handles build + restart.

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Daemon is truth, GRDB is cache | Mac can go offline; daemon owns state |
| Single WebSocket | Atomic reconnect, no partial failures, simpler multiplexing |
| Hardcoded for beast | No multi-host abstraction — eliminates generic SSH complexity |
| tmux for persistence | Sessions survive everything (app quit, SSH drops, daemon restarts) |
| GhosttyKit for terminals | GPU-accelerated Metal rendering, same quality as standalone Ghostty |
| PTY shim relay | Bridges ghostty (expects local process) to remote terminal over WebSocket |
| `.threadmill.yml` in project repo | Versioned config, shared with team |
| Port offset allocation | Multiple dev servers per project don't conflict |

---

## Terminal I/O Data Path

```
ghostty surface ←→ PTY ←→ threadmill-relay ←→ Unix socket ←→ WebSocket ←→ Spindle ←→ tmux pane
```

Binary frames: `[u16be channel_id][raw terminal bytes]`. Not JSON. See `docs/agents/communication-protocol.md`.

---

## Protocol Quick Reference

**RPC methods** (Mac → Spindle): `ping`, `project.{list,add,clone,remove,branches}`, `thread.{create,list,close,hide,reopen}`, `terminal.{attach,detach,resize}`, `preset.{start,stop,restart}`, `state.snapshot`

**Events** (Spindle → Mac): `thread.progress`, `thread.status_changed`, `thread.created`, `preset.process_event`, `project.added`, `project.removed`, `project.clone_progress`, `state.delta`

Full protocol reference: `docs/agents/communication-protocol.md`
JSON schema: `protocol/threadmill-rpc.schema.json`

---

## Environment Variables in tmux Sessions

Every tmux session gets these env vars:

| Variable | Example |
|---|---|
| `THREADMILL_PROJECT` | `myautonomy` |
| `THREADMILL_THREAD` | `feature-auth` |
| `THREADMILL_BRANCH` | `feature-auth` |
| `THREADMILL_WORKTREE` | `/home/wsl/dev/.threadmill/myautonomy/feature-auth` |
| `THREADMILL_MAIN` | `/home/wsl/dev/myautonomy` |
| `THREADMILL_PORT_OFFSET` | `0` (or 20, 40, ...) |
| `THREADMILL_PORT_BASE` | `3000` (base + offset) |

---

## Testing Conventions

- **One test per feature.** Not more.
- Swift tests use `XCTest`, mock doubles in `TestDoubles.swift`, DI via protocols in `Abstractions.swift`.
- Spindle tests are integration tests against a real daemon instance (test helpers in `tests/common/`).
- UI e2e tests use `MockSpindleServer` and require `THREADMILL_RUN_UI_E2E=1`.
- All tests `@MainActor` on the Swift side (AppState and most components are MainActor-bound).

---

## Retrievable Documentation

| File | Description |
|---|---|
| `docs/agents/communication-protocol.md` | WebSocket JSON-RPC protocol, activity diagrams, RPC methods, events, binary frames |
| `docs/agents/validation.md` | Build/test commands, test suites, CI expectations |
| `docs/architecture.md` | Full architecture spec, module structure, milestone status |
| `docs/vision.md` | Product vision, feature status, milestone checklist |
| `protocol/threadmill-rpc.schema.json` | JSON-RPC schema (types, methods, events) |
