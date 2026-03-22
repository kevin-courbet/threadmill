---
updated: 2026-03-23
---

# Validation Process

## Quick Reference

- Run `task validate` to execute the full gate: build Threadmill, build Spindle (via beast), then run all test suites.

## Commands

- `task build`: build local Threadmill (`swift build`).
- `task build:spindle`: build remote Spindle on beast over SSH.
- `task build:all`: run both builds.
- `task test:swift`: run Threadmill Swift unit tests.
- `task test:integration`: run real Spindle integration tests (requires beast + SSH tunnel).
- `task test:spindle`: run Spindle Rust tests on beast over SSH.
- `task test:ui`: run UI e2e tests (`THREADMILL_RUN_UI_E2E=1`), requires macOS Accessibility permission.
- `task test`: run `test:swift` and `test:spindle`.
- `task validate`: run `build:all` and `test`.

## Test Directory Structure

```
Tests/ThreadmillTests/
├── Shared/          # TestDoubles.swift — mock doubles shared by unit + integration
├── Unit/            # ~186 unit tests with mock doubles
└── Integration/     # Real Spindle integration tests (beast + SSH tunnel)
    ├── SpindleConnection.swift       # Lightweight WebSocket client for test harness
    ├── IntegrationTestCase.swift     # Base class: setUp sweep, tearDown cleanup, helpers
    ├── ProjectIntegrationTests.swift
    ├── ThreadIntegrationTests.swift
    ├── TerminalIntegrationTests.swift
    ├── PresetIntegrationTests.swift
    └── ChatIntegrationTests.swift
```

## Test Suites

- **Swift unit tests** (~186 tests in `Unit/`):
  - `TerminalMultiplexer` (pre-registration buffer)
  - `AppState` events, attach behavior, project management, remote connections
  - `RelayEndpoint` bounds
  - `ConnectionManager` reconnect behavior
  - `ThreadTabStateManager` mode switching + persistence
  - `BrowserSessionManager` session lifecycle
  - `FileBrowserViewModel` directory listing, error states
  - `ChatConversation` GRDB persistence
  - `ChatSessionViewModel` ACP streaming + timeline building
  - `AgentSessionManager` channel lifecycle, binary frame routing, reconnect
  - `TimelineModel` item types, exploration clustering, turn summaries
  - `IntegrationFlow` mock-based end-to-end validation (repo, thread, terminals, ACP chat)
  - `DatabaseMigrationV6` remote/repo model migrations
  - Source-level structural tests (window chrome, tab styling, syntax highlighting)

- **Spindle integration tests** (6 tests in `Integration/`, one file per domain):
  - `ProjectIntegrationTests` — project.add, project.list with fixture repo
  - `ThreadIntegrationTests` — thread.create, wait for status_changed event, verify worktree via SSH
  - `TerminalIntegrationTests` — terminal.attach, binary frame echo round-trip
  - `PresetIntegrationTests` — preset.start, verify preset.process_event
  - `ChatIntegrationTests` — ACP agent.start, initialize, session/new, prompt, verify session/update; full GRDB + ACP round-trip

  These tests connect to the real Spindle daemon on beast via SSH tunnel. They use a dedicated fixture repo at `/home/wsl/dev/threadmill-test-fixture`. Test threads use a `test-` prefix; stale threads are swept on each run.

- **Spindle Rust tests** (~35 tests) cover:
  - project/thread/terminal/preset lifecycle
  - file.list/file.read/file.git_status with path authorization
  - sync protocol behavior
  - binary frame routing
  - agent process management
  - CLI commands

- **UI e2e tests** cover full app flow with a mock daemon; opt-in and requires Accessibility permission.

## Adding New Tests

- Unit tests go in `Tests/ThreadmillTests/Unit/`.
- Integration tests go in `Tests/ThreadmillTests/Integration/`, one file per domain. Subclass `IntegrationTestCase` for connection helpers, thread lifecycle, and ACP setup.
- Shared test doubles go in `Tests/ThreadmillTests/Shared/`.
- Spindle Rust tests are maintained on beast under `/home/wsl/dev/spindle/tests/`.
- UI e2e tests live under `UITests/ThreadmillUITests/`.

## CI Expectation

- `task validate` must pass before merge.

## Remote Execution Note

- Spindle build/tests are executed on host `beast` via SSH, not in the local Threadmill checkout.
- Integration tests require the SSH tunnel to be up (port 19990). `task test:integration` handles tunnel setup.
