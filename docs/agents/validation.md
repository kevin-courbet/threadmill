---
updated: 2026-03-25
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
- `task test:ui`: run XCUI e2e tests (requires beast + SSH tunnel + Accessibility permission).
- `task test`: run `test:swift` and `test:spindle`.
- `task validate`: run `build:all` and `test`.

## Test Directory Structure

```
Tests/ThreadmillTests/
├── Shared/          # TestDoubles.swift — mock doubles shared by unit + integration
├── Unit/            # Behavioral unit tests with mock doubles
└── Integration/     # Real Spindle integration tests (beast + SSH tunnel)

UITests/
└── ThreadmillUITests/           # XCUI e2e tests (Xcode project, real Spindle)
    └── ThreadmillUITests.xcodeproj
```

## Test Suites

- **Swift unit tests** (`Tests/ThreadmillTests/Unit/`):
  - `TerminalMultiplexer` — channel routing, pre-registration buffer, reconnect remapping
  - `AppState` — events, attach behavior, project management, remote connections, thread lifecycle
  - `RelayEndpoint` — bounded frame buffer, channel gate
  - `ConnectionManager` — reconnect with backoff, state transitions
  - `ThreadTabStateManager` — mode switching, persistence, stale fallback
  - `BrowserSessionManager` — CRUD lifecycle, selection
  - `FileBrowserViewModel` — directory listing, git status, error states
  - `ChatConversation` — GRDB persistence lifecycle
  - `ChatSessionViewModel` — ACP streaming, timeline building, agent/mode selection
  - `AgentSessionManager` — channel lifecycle, binary frame deframing, reconnect
  - `TimelineModel` — item types, exploration clustering, turn summaries, streaming deltas
  - `IntegrationFlow` — mock-based end-to-end (repo, thread, terminals, ACP chat)
  - `DatabaseMigration` — remote/repo model migrations, column renames
  - `GitHubClient` — pagination, 401 handling, SSH clone URL preference
  - `GitHubAuthManager` — device flow, token persistence
  - `ProvisioningService` — repo registration, clone, error paths
  - `FileSyntaxHighlighting` — tree-sitter loading, language detection
  - `KeyboardShortcut` — thread selection, preset tab cycling
  - `RemoteConnectionPool` — lifecycle, activation, add/update/remove
  - `SyncService` — daemon sync RPC delegation

- **Spindle integration tests** (`Tests/ThreadmillTests/Integration/`, one file per domain):
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

- **UI e2e tests** (`UITests/ThreadmillUITests/`, Xcode project):
  - Launches real app against real Spindle on beast
  - Fixture thread created via `Scripts/setup_xcui_fixture.swift`
  - Tests: terminal prompt, session creation, named preset via dropdown

## Adding New Tests

- Unit tests go in `Tests/ThreadmillTests/Unit/`. See `docs/agents/unit-testing.md` for standards.
- Integration tests go in `Tests/ThreadmillTests/Integration/`, one file per domain. Subclass `IntegrationTestCase` for connection helpers, thread lifecycle, and ACP setup.
- Shared test doubles go in `Tests/ThreadmillTests/Shared/`.
- Spindle Rust tests are maintained on beast under `/home/wsl/dev/spindle/tests/`.
- UI e2e tests go in `UITests/ThreadmillUITests/`.

## CI Expectation

- `task validate` must pass before merge.

## Remote Execution Note

- Spindle build/tests are executed on host `beast` via SSH, not in the local Threadmill checkout.
- Integration tests require the SSH tunnel to be up (port 19990). `task test:integration` handles tunnel setup.
