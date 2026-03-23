# Integration Tests

Two layers, both hit real Spindle on beast via SSH tunnel.

## Protocol/ — Raw WebSocket ↔ Spindle

Tests Spindle RPC correctness. Uses `SpindleConnection` (lightweight WebSocket client) to send JSON-RPC and binary frames directly. Does NOT exercise any Swift app code (AppState, ConnectionManager, AgentSessionManager, etc.).

**What it catches:** Spindle bugs, protocol regressions, event payloads.
**What it misses:** Swift-side wiring bugs (SQL queries, connection ordering, FK constraints, frame routing).

## AppStack/ — Real Swift classes ↔ real Spindle

Tests the actual app code paths against real Spindle. Uses real `AppState`, `ConnectionManager`, `AgentSessionManager`, `DatabaseManager`, `TerminalMultiplexer`, etc. — the same objects the running app uses, pointed at real Spindle.

**What it catches:** Everything Protocol catches + Swift-side wiring (the bugs that made the app broken while mock tests passed).
**What it misses:** UI rendering (that's UITests/).

## When to add which

- New Spindle RPC or event → add Protocol test
- New Swift feature that wires through AppState/ConnectionManager → add AppStack test
- Both, when the feature spans Spindle + Swift
