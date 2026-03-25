---
updated: 2026-03-25
---

# Debugging Guide

## Logging Architecture

All production logging uses Apple's unified `os.Logger` system (`import os`). No `NSLog`, `print()`, or custom file-based loggers.

### Logger Categories

Defined in `Sources/Threadmill/Support/Log.swift`. Subsystem: `dev.threadmill`.

| Logger | Category | Domain |
|---|---|---|
| `Logger.boot` | `boot` | App bootstrap, lifecycle |
| `Logger.state` | `state` | AppState: selection, events, attach flow |
| `Logger.conn` | `conn` | ConnectionManager: connect/disconnect/reconnect |
| `Logger.tunnel` | `tunnel` | SSH tunnel lifecycle |
| `Logger.sync` | `sync` | SyncService: daemon → GRDB sync |
| `Logger.mux` | `mux` | TerminalMultiplexer: channel dispatch |
| `Logger.relay` | `relay` | RelayEndpoint: PTY shim, binary frames |
| `Logger.ghostty` | `ghostty` | GhosttySurfaceHost: surface create/free |
| `Logger.agent` | `agent` | AgentSessionManager: ACP sessions |
| `Logger.browser` | `browser` | BrowserSessionManager: tab CRUD |
| `Logger.github` | `github` | GitHub OAuth device flow |
| `Logger.view` | `view` | View-layer tracing (mode switching, restore) |

### Log Levels

| Level | Usage |
|---|---|
| `.debug` | Verbose — only visible with explicit Console.app filter |
| `.info` | Lifecycle transitions, state changes, expected flow |
| `.notice` | Noteworthy but expected (e.g. "CONNECTED") |
| `.error` | Recoverable failures (RPC errors, attach failures) |
| `.fault` | Unrecoverable / invariant violations |

### Usage

```swift
import os

Logger.state.info("attachPreset thread=\(threadID, privacy: .public) preset=\(preset, privacy: .public)")
Logger.conn.error("Connect failed: \(error)")
Logger.relay.debug("BUFFERING \(frame.count - 2) bytes for \(self.threadID)/\(self.preset)")
```

Use `privacy: .public` for identifiers (thread IDs, preset names) that are safe to expose. Error descriptions default to redacted in release builds — omit the privacy annotation for them.

### Adding a New Category

1. Add a static `Logger` to `Sources/Threadmill/Support/Log.swift`
2. Update this table

## Debugging Tests (Red-Green-Refactor)

### Why os.Logger Matters for TDD

`NSLog` output is invisible during `swift test` — it goes to the unified system log, not stdout. With `os.Logger`, tests can programmatically capture and dump logs via `OSLogStore` when a test fails.

### Integration Test Log Capture

`IntegrationTestCase` (the base class for all Spindle integration tests) automatically captures `dev.threadmill` logs during each test. On failure, all structured log entries from the test's duration are dumped to stdout.

This means when a Red test fails, you get the full connection/state/sync trail alongside the assertion failure — no manual Console.app tailing needed.

**Automatic dump on failure** — no action required. The `addTeardownBlock` in `setUp()` checks `testRun?.failureCount` and dumps if > 0.

**Manual dump during test** — call `dumpLogs()` or `dumpLogs(category: "conn")` in your test body:

```swift
func testConnectionReconnect() async throws {
    let conn = try await makeConnection()
    // ... trigger failure ...
    dumpLogs(category: "conn")  // dump only connection logs
    dumpLogs()                  // dump all categories
}
```

### Verbose Test Output

All test tasks use `--verbose` so test case names appear as they run. This catches timeout hangs — without it, a stuck test is a silent wait.

```bash
task test:swift          # unit tests with --verbose
task test:integration    # integration tests with --verbose
```

### Console.app Filtering (Manual Debugging)

For debugging a running app or exploring log flow outside tests:

1. Open Console.app
2. Filter: `subsystem:dev.threadmill`
3. Narrow: `subsystem:dev.threadmill category:conn`
4. Show Info + Debug messages via Action → Include Info/Debug Messages

### Debugging Workflow (Red Phase)

1. Write a failing test
2. Run `task test:swift` (or `task test:integration`)
3. Test fails → structured logs dumped to stdout automatically
4. Identify the failure path from log categories (conn, state, sync, etc.)
5. Write minimum fix (Green)
6. Refactor, re-run tests

## Enforcement

### Banned Patterns

These are enforced by pre-commit hook and `task lint`:

| Pattern | Replacement |
|---|---|
| `NSLog(...)` | `Logger.<category>.<level>(...)` |
| `print(...)` in Sources/ | `Logger.<category>.<level>(...)` |
| `trace(...)` | `Logger.view.info(...)` or appropriate category |

### Pre-Commit Hook

`.git/hooks/pre-commit` checks all staged `.swift` files under `Sources/` for `NSLog(` and `print(`. Fails the commit if found.

### Lint Task

```bash
task lint
```

Runs `Scripts/lint_logging.sh` — checks the entire `Sources/` tree. Use in CI or before PRs.

### Adding SwiftLint (Optional)

If SwiftLint is installed (`brew install swiftlint`), add a `.swiftlint.yml` with:

```yaml
custom_rules:
  no_nslog:
    regex: '\bNSLog\('
    message: "Use Logger.<category> from os.Logger instead of NSLog"
    severity: error
  no_print:
    regex: '\bprint\('
    message: "Use Logger.<category> from os.Logger instead of print"
    severity: error
    included: Sources/
```

The grep-based hook and lint script work without SwiftLint and are the primary enforcement.
