# Integration Tests

Three layers, all hit real Spindle on beast via SSH tunnel.

## Protocol/ — Raw WebSocket ↔ Spindle

Tests Spindle RPC correctness. Uses `SpindleConnection` (lightweight WebSocket client) to send JSON-RPC and binary frames directly. Does NOT exercise any Swift app code.

**Catches:** Spindle bugs, protocol regressions, event payloads.
**Run:** `task test:integration` or `swift test --filter IntegrationTests`

## AppStack/ — Real Swift classes ↔ real Spindle

Tests actual app code paths (AppState, ConnectionManager, DatabaseManager, etc.) against real Spindle. No UI.

**Catches:** Swift-side wiring bugs (SQL queries, connection ordering, FK constraints, frame routing).

## UITests/ — XCUI e2e against real Spindle

Full end-to-end: launches real app, connects to real Spindle, interacts via XCUIApplication. Lives in `UITests/ThreadmillUITests/`.

**Catches:** UI rendering bugs, accessibility, visual state after user interactions.
**Run:** `task test:ui`

### XCUI fixture procedure

All XCUI tests use `TestHarness` (in `UITests/ThreadmillUITests/TestHarness.swift`):

1. **Fresh DB** — `THREADMILL_DB_PATH` → temp directory. App sees ONLY fixture data.
2. **Seeded Remote** — `ensureDefaultRemoteExists()` (app's own bootstrap), then host/tunnel updated to `127.0.0.1:19990`.
3. **Fixture on Spindle** — `Scripts/setup_xcui_fixture.swift` creates the fixture project + thread on beast BEFORE app launch. Runs from Taskfile because the test runner is sandboxed.
4. **App syncs on connect** — real `SyncService` populates the fresh DB. Sidebar shows only fixture data.
5. **No mock data** — everything through real code paths.

### Writing a new XCUI test

```swift
@MainActor
final class MyFeatureTests: XCTestCase {
    private var harness: TestHarness?

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TestHarness.launch()
    }

    override func tearDownWithError() throws {
        harness?.tearDown()
        harness = nil
        try super.tearDownWithError()
    }

    func testSomething() throws {
        guard let harness else { throw XCTSkip("Harness not available") }
        guard let thread = harness.waitForFixtureThread() else {
            XCTFail("Fixture thread not found"); return
        }
        thread.click()
        try harness.selectMode("mode.tab.terminal")
        harness.screenshot(name: "my-state", testCase: self)
        // assert...
    }
}
```

### XCUI tests do NOT run by default

They require beast + SSH tunnel + Accessibility + built app. Run only when:
- Developing a feature with RDR (run the specific test)
- Verifying a UI bug fix
- Full sweep: `task test:ui`

## When to add which

- Spindle RPC/event → Protocol test
- Swift wiring (AppState/ConnectionManager) → AppStack test
- UI bug, visual regression, interaction flow → XCUI test
