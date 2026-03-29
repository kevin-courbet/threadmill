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
| `task test:integration` | Real Spindle integration tests (requires beast + SSH tunnel) |
| `task test:spindle` | Spindle Rust tests on beast via SSH |
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
├── WKWebView browser                               ├── threads.json state store
└── PTY shim relay (threadmill-relay)                ├── File service (list/read/git_status)
                                                     └── threadmill-cli (agent CLI)
```

**Daemon is truth.** GRDB on Mac is a rendering cache. On every connect, Mac syncs from daemon.

**Single WebSocket.** All JSON-RPC requests, events, and terminal binary frames share one connection over one SSH tunnel. No per-tab connections.

---

## UI Architecture

The detail view uses a **mode switcher** (segmented picker) with four modes:
- **Chat** — ACP agent conversations, multi-session tabs, GRDB-persisted
- **Terminal** — remote terminals via Spindle, multi-session ZStack (kept alive), preset-based
- **Files** — remote file browser via Spindle RPCs, tree + content viewer with syntax highlighting
- **Browser** — WKWebView tabs, GRDB-persisted, default URL = localhost + port offset

Each mode has session tabs in the toolbar (capsule-styled, aizen-inspired). Window uses `.hiddenTitleBar` + `.windowToolbarStyle(.unified)`.

---

## Two Codebases

### Threadmill (this repo) — macOS Swift app

| Path | Purpose |
|---|---|
| `Package.swift` | SPM manifest (macOS 14+, GRDB, GhosttyKit xcframework) |
| `Taskfile.yml` | go-task runner for build/test/run/validate |
| `protocol/threadmill-rpc.schema.json` | JSON-RPC schema (source of truth for types) |
| **Sources/Threadmill/** | |
| `App/ThreadmillApp.swift` | SwiftUI @main entry, hiddenTitleBar, unified toolbar, dark mode |
| `App/AppDelegate.swift` | NSApplicationDelegateAdaptor, bootstrap connection + sync |
| `App/AppState.swift` | Central @Observable state — event handling, attach flow, thread/project/file actions |
| `Connection/WebSocketClient.swift` | URLSessionWebSocketTask JSON-RPC + binary frames |
| `Connection/SSHTunnelManager.swift` | SSH tunnel child process lifecycle |
| `Transport/ConnectionManager.swift` | Connection state machine, reconnect with backoff, DI-friendly |
| `Transport/TerminalMultiplexer.swift` | channel_id → RelayEndpoint dispatch + preRegistrationBuffer |
| `Transport/AgentSessionManager.swift` | ACP binary frame relay, per-channel deframing, session lifecycle |
| `Transport/RelayEndpoint.swift` | Per-terminal Unix socket + bounded frame buffer |
| `Terminal/GhosttySurfaceHost.swift` | ghostty_app lifecycle, surface registry, callbacks |
| `Terminal/GhosttyTerminalView.swift` | NSViewRepresentable, endpoint swap on thread switch |
| `Terminal/GhosttyNSView.swift` | Raw NSView for Metal surface hosting |
| `Database/DatabaseManager.swift` | GRDB setup + migrations (v1 base → v10 chat_conversation_agent_session) |
| `Database/SyncService.swift` | project.list + thread.list sync from daemon |
| `Database/ChatConversationService.swift` | GRDB CRUD for chat conversations per thread |
| `Models/Project.swift` | Project + PresetConfig (includes presets from daemon) |
| `Models/Thread.swift` | ThreadModel with portOffset |
| `Models/Preset.swift` | Preset enum + defaults |
| `Models/ThreadStatus.swift` | Status enum (creating/active/closing/closed/hidden/failed) |
| `Models/TabItem.swift` | Mode switcher tabs (chat/terminal/files/browser) with icons |
| `Models/AgentConfig.swift` | Agent config (name, command, cwd) from .threadmill.yml |
| `Models/TimelineItem.swift` | Timeline model: message, tool call, tool call group, turn summary |
| `Models/ToolCallGroup.swift` | Tool call grouping + ExplorationCluster for read/search/grep runs |
| `Models/ChatConversation.swift` | GRDB record for chat sessions per thread (agentSessionID + agentType) |
| `Models/BrowserSession.swift` | GRDB record for browser tabs per thread |
| `Support/Abstractions.swift` | DI protocols: ConnectionManaging, DatabaseManaging, FileBrowsing, etc. |
| `Support/Log.swift` | os.Logger category extensions (subsystem: dev.threadmill) |
| `Features/Projects/SidebarView.swift` | Sidebar with project sections |
| `Features/Projects/ProjectSection.swift` | Per-project disclosure group + thread rows |
| `Features/Projects/AddProjectSheet.swift` | Open existing project on beast |
| `Features/Projects/CloneRepoSheet.swift` | Clone repo by URL |
| `Features/Threads/ThreadDetailView.swift` | Mode switcher + session tabs + content switching |
| `Features/Threads/ThreadRow.swift` | Sidebar row with status + branch |
| `Features/Threads/NewThreadSheet.swift` | Create thread with project preselection |
| `Features/Threads/ThreadTabStateManager.swift` | Persists selected mode + session IDs per thread (@AppStorage JSON) |
| `Features/Chat/ChatSessionView.swift` | Chat session container — ACP-backed timeline rendering |
| `Features/Chat/ChatSessionViewModel.swift` | Chat VM — ACP streaming, timeline building, tool call grouping |
| `Features/Chat/ChatInputBar.swift` | NSTextView composer (Enter=send, Shift+Enter=newline, agent/mode selector) |
| `Features/Chat/ChatMessageList.swift` | LazyVStack timeline with virtual window and load-more |
| `Features/Chat/MessageBubbleView.swift` | User/agent message bubbles (right-aligned user, full-width agent) |
| `Features/Chat/ToolCallView.swift` | Expandable tool call accordion with status dot + syntax highlighting |
| `Features/Chat/ToolCallGroupView.swift` | Collapsible group of tool calls with exploration cluster summaries |
| `Features/Chat/TurnSummaryView.swift` | Inter-turn divider with tool count and duration |
| `Features/Chat/ChatProcessingIndicator.swift` | Spinning arc + shimmer thought text during agent processing |
| `Features/Browser/BrowserView.swift` | Browser with internal tab bar, WKWebView |
| `Features/Browser/BrowserControlBar.swift` | URL field, back/forward/reload, progress bar |
| `Features/Browser/BrowserSessionManager.swift` | GRDB-backed browser session management |
| `Features/Browser/WebViewWrapper.swift` | WKWebView NSViewRepresentable with KVO + delegates |
| `Features/Files/FileBrowserView.swift` | HStack split layout: tree sidebar + content viewer |
| `Features/Files/FileBrowserViewModel.swift` | File operations via Spindle RPCs, git status |
| `Features/Files/FileTreeView.swift` | Recursive directory tree with git status coloring |
| `Features/Files/FileContentTabView.swift` | Open file tabs with shared tab components |
| `Features/Files/CodeEditorView.swift` | CodeEditSourceEditor-based editor with tree-sitter highlighting |
| `Features/Files/LanguageDetection.swift` | File extension → language mapping |
| `Views/ContentView.swift` | NavigationSplitView, sidebar width |
| `Views/Components/SessionTabsScrollView.swift` | Capsule session tabs with arrows, +, context menus |
| `Views/Components/TabContainer.swift` | Reusable tab container (top accent border, separator) |
| `Views/Components/TabLabel.swift` | Tab label with icon + title slots |
| `Views/Components/TabCloseButton.swift` | xmark close button with hover states |
| `Views/Components/FileIconView.swift` | SF Symbol file type icons by extension |
| `Views/Components/AnimatedGradientBorder.swift` | Conic gradient rotation border for streaming/plan/idle states |
| `Views/Components/ScrollBottomObserver.swift` | NSScrollView KVO observer with hysteresis + jump-to-bottom |
| `Views/Components/ShimmerEffect.swift` | CAGradientLayer sweep animation for thinking text |
| `Views/Components/ConnectionStatusView.swift` | Reusable connection status dot view |
| **Sources/threadmill-relay/** | |
| `main.c` | ~30-line C PTY bridge: stdin/stdout ↔ Unix socket |
| **Tests/ThreadmillTests/Shared/** | TestDoubles.swift — mock doubles shared by unit + integration |
| **Tests/ThreadmillTests/Unit/** | Behavioral unit tests with mock doubles |
| **Tests/ThreadmillTests/Integration/** | Real Spindle integration tests (beast + SSH tunnel) |
| `Integration/Protocol/SpindleConnection.swift` | Lightweight WebSocket client for test harness |
| `Integration/Protocol/IntegrationTestCase.swift` | Base class: setUp sweep, tearDown cleanup, OSLogStore dump-on-failure |
| `Integration/Protocol/{Project,Thread,Terminal,Preset,Chat}IntegrationTests.swift` | One file per domain |
| `Integration/AppStack/AppStackTestCase.swift` | Base class using real AppState + ConnectionManager + GRDB |
| **UITests/ThreadmillUITests/** | XCUI e2e tests (Xcode project, real Spindle on beast) |

### Spindle (on beast) — Rust daemon

Beast's `/home/wsl/dev` is NFS-mounted at `/Volumes/wsl-dev`. **Edit Spindle files locally** at `spindle/` (symlink → `/Volumes/wsl-dev/spindle/`, gitignored) — no SSH needed for reads/writes. Use SSH only for commands (`cargo build`, `systemctl`, etc.).

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
| `src/services/terminal.rs` | terminal.attach/detach/resize, channel allocation, pipe-pane relay, scrollback replay |
| `src/services/preset.rs` | preset.start/stop/restart, process monitoring, config-driven commands, base preset name resolution for multi-instance tabs |
| `src/services/file.rs` | file.list/file.read/file.git_status, path authorization, TOCTOU hardening |
| `src/bin/threadmill-cli.rs` | CLI for agent-side automation (clap) |
| `tests/` | Integration tests (project, thread, terminal, preset, file, sync, binary, CLI) |

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
| Mode switcher (aizen pattern) | Chat/Terminal/Files/Browser modes with session tabs per mode |
| GRDB for conversations + browser | Local persistence for chat/browser state across app restarts |
| CodeEditSourceEditor + tree-sitter | Accurate language parsing and highlighting via CodeEditLanguages queries |

---

## Terminal I/O Data Path

```
ghostty surface ←→ PTY ←→ threadmill-relay ←→ Unix socket ←→ WebSocket ←→ Spindle ←→ tmux pane
```

Binary frames: `[u16be channel_id][raw terminal bytes]`. Not JSON. See `docs/agents/communication-protocol.md`.

---

## Protocol Quick Reference

**RPC methods** (Mac → Spindle): `ping`, `project.{list,add,clone,remove,branches}`, `thread.{create,list,close,hide,reopen}`, `terminal.{attach,detach,resize}`, `preset.{start,stop,restart}`, `agent.{start,stop}`, `file.{list,read,git_status}`, `state.snapshot`

**Events** (Spindle → Mac): `thread.progress`, `thread.status_changed`, `thread.created`, `preset.process_event`, `agent.status_changed`, `project.added`, `project.removed`, `project.clone_progress`, `state.delta`

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

## Logging

All production logging uses `os.Logger` (subsystem `dev.threadmill`). Categories defined in `Sources/Threadmill/Support/Log.swift`. `NSLog` and `print()` are banned in `Sources/` — enforced by pre-commit hook and `task lint`. See `docs/agents/debugging.md` for the full logging policy, log levels, and test debugging workflow.

---

## Testing Conventions

- **Every test must verify behavior** — state transitions, error paths, protocol contracts, or business logic. See `docs/agents/unit-testing.md`.
- **Never write source-reading tests** — reading `.swift` files and asserting on string contents is banned.
- **Never write trivially shallow tests** — don't test struct init field assignment or mock recording.
- **Never use mock server patterns** — fake server/hardcoded response tests (including the deleted `MockSpindleServer` pattern) are banned; use real Spindle `TestHarness` e2e coverage.
- Swift tests use `XCTest`, mock doubles in `TestDoubles.swift`, DI via protocols in `Abstractions.swift`.
- Spindle tests are integration tests against a real daemon instance (test helpers in `tests/common/`).
- All tests `@MainActor` on the Swift side (AppState and most components are MainActor-bound).
- **Integration test log capture**: `IntegrationTestCase` auto-dumps `dev.threadmill` logs on failure via `OSLogStore`.

---

## Retrievable Documentation

| File | Description |
|---|---|
| `docs/agents/debugging.md` | Logging architecture, os.Logger categories, test debugging workflow, enforcement rules |
| `docs/agents/communication-protocol.md` | WebSocket JSON-RPC protocol, activity diagrams, RPC methods, events, binary frames |
| `docs/agents/unit-testing.md` | Unit testing standards, banned patterns, what makes a good test, test organization |
| `docs/agents/validation.md` | Build/test commands, test suites, CI expectations |
| `docs/architecture.md` | Full architecture spec, module structure, milestone status |
| `docs/vision.md` | Product vision, feature status, milestone checklist |
| `protocol/threadmill-rpc.schema.json` | JSON-RPC schema (types, methods, events) |
| `docs/agents/swiftui-patterns.md` | SwiftUI/AppKit patterns: @Observable+@State rules, DisclosureGroup custom chevron, hover states, Settings window, GhosttyKit theming |
| `.opencode/skills/threadmill-debugging/SKILL.md` | Full-stack debugging: layer triage, logging, connection/terminal/UI/accessibility/test debugging procedures |
