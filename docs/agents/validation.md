---
updated: 2026-02-24
---

# Validation Process

## Quick Reference

- Run `task validate` to execute the full gate: build Threadmill, build Spindle (via beast), then run all test suites.

## Commands

- `task build`: build local Threadmill (`swift build`).
- `task build:spindle`: build remote Spindle on beast over SSH.
- `task build:all`: run both builds.
- `task test:swift`: run Threadmill Swift unit tests.
- `task test:spindle`: run Spindle integration tests on beast over SSH.
- `task test:ui`: run UI e2e tests (`THREADMILL_RUN_UI_E2E=1`), requires macOS Accessibility permission.
- `task test`: run `test:swift` and `test:spindle`.
- `task validate`: run `build:all` and `test`.

## Test Suites

- Swift unit tests (14 tests):
  - `TerminalMultiplexer`
  - `AppState` events
  - `RelayEndpoint` bounds
  - `ConnectionManager` reconnect behavior
- Spindle integration tests cover:
  - project/thread/terminal/preset lifecycle
  - sync protocol behavior
  - binary frame routing
- UI e2e tests cover full app flow with a mock daemon; opt-in and requires Accessibility permission.

## Adding New Tests

- Swift tests go in `Tests/` under the relevant test target.
- Use Swift `XCTest` naming conventions:
  - file names: `*Tests.swift`
  - test functions: `test...`
- Spindle integration tests are maintained in the Spindle repository on beast under `/home/wsl/dev/spindle`.
- UI e2e tests should live with the existing UI test target and be runnable via `swift test --filter ThreadmillUITests` when opt-in env is set.

## CI Expectation

- `task validate` must pass before merge.

## Remote Execution Note

- Spindle build/tests are executed on host `beast` via SSH, not in the local Threadmill checkout.
