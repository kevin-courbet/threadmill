# PRD: XCUITest E2E Infrastructure

## Problem

Threadmill has no reliable end-to-end UI testing. Previous attempts used raw `AXUIElement` traversal which cannot reliably see controls inside `NavigationSplitView` detail panes. Fake automation controls were added as a workaround, creating divergent test/production paths. All of that has been removed. We need a proper E2E test foundation that:

- Drives the real production UI, not a test-only layout
- Can see and interact with all controls, including detail pane content
- Does not interfere with the developer's other windows during test runs
- Validates real user workflows against a mock daemon

## Solution

Use Apple's XCUITest framework via a minimal Xcode project wrapper. Keep SPM as the source of truth for app code and unit tests. Add a separate Xcode project solely for UI test bundles. Launch the real SPM-built `.app` bundle in tests, attach via `XCUIApplication(bundleIdentifier:)`, and drive the UI through XCUIElement queries.

## Requirements

### Must Have

- [ ] Minimal Xcode project at `UITests/ThreadmillUITests.xcodeproj` containing one UI Testing Bundle target
- [ ] UI test bundle launches the SPM-built `Threadmill.app` via `Process`, then attaches with `XCUIApplication(bundleIdentifier: "dev.threadmill.app")`
- [ ] `MockSpindleServer` (WebSocket mock daemon) available in the UI test bundle for RPC observation
- [ ] Environment variables passed to launched app: `THREADMILL_DISABLE_SSH_TUNNEL`, `THREADMILL_HOST`, `THREADMILL_DAEMON_PORT`, `THREADMILL_DB_PATH`, `THREADMILL_USE_MOCK_TERMINAL`
- [ ] Database seeding helper for remotes and repos
- [ ] `task test:ui` command that builds the app via SPM then runs `xcodebuild test` against the UI test project
- [ ] Validation test case passes: navigate to project A, create 2 preset terminals, navigate to project B, create 2 preset terminals

### Nice to Have

- [ ] Accessibility identifiers audit: ensure every interactive control has a deterministic, stable identifier
- [ ] Test helper for waiting on mock server RPC calls
- [ ] Reusable test fixture for multi-project + multi-thread scenarios

## Technical Approach

### Architecture

```
Package.swift                     # App + unit tests (SPM, unchanged)
Sources/Threadmill/               # App code
Tests/ThreadmillTests/            # Unit tests (SPM)
UITests/
  ThreadmillUITests.xcodeproj     # Minimal Xcode project for UI test bundle only
  ThreadmillUITests/
    Info.plist
    MockSpindleServer.swift       # WebSocket mock daemon (copied/shared from existing)
    TestHelpers.swift             # App launch, DB seeding, RPC wait helpers
    TerminalCreationTests.swift   # Validation test case
```

### Key Design Decisions

**Why a separate Xcode project?**
XCUITest requires a UI Testing Bundle target type, which SPM does not support. A minimal `.xcodeproj` containing only the test bundle keeps the app build in SPM while getting real XCUITest capabilities.

**Why `XCUIApplication(bundleIdentifier:)` instead of `XCUIApplication()`?**
`XCUIApplication()` requires the test target to have a configured "Target Application" in the Xcode scheme, which would mean building the app through Xcode. We want to build via SPM and launch the `.app` bundle ourselves via `Process`, then attach XCUITest to the running app by bundle identifier.

**Why `Process` launch instead of `XCUIApplication.launch()`?**
We need to pass custom environment variables (mock daemon port, DB path, SSH tunnel disable) that control the app's connection behavior. `Process` gives us full control over the launch environment. `XCUIApplication(bundleIdentifier:)` then attaches to observe and drive the UI.

**Why copy MockSpindleServer into the UI test bundle?**
The UI test bundle is a separate Xcode target that cannot import SPM test targets. The mock server is self-contained (~700 lines) and can be copied directly. If it grows, we can extract it into a shared SPM library target later.

### App Launch Flow in Tests

```
1. MockSpindleServer.start() → listening on random port
2. Seed GRDB database with remote (host=127.0.0.1, port=mock, useSSHTunnel=false) + repos
3. Process.run(Threadmill.app, env: {DAEMON_PORT, DB_PATH, DISABLE_SSH, MOCK_TERMINAL})
4. XCUIApplication(bundleIdentifier: "dev.threadmill.app").activate()
5. Wait for app.windows.firstMatch.waitForExistence(timeout: 15)
6. Wait for MockSpindleServer to receive "session.hello" (connection established)
7. Wait for MockSpindleServer to receive "project.list" (sync complete)
8. Test interactions begin
```

### Validation Test Case

**Test: Create 2 preset terminals in project A, then 2 in project B**

```
Setup:
- MockSpindleServer with 2 projects, each having presets [terminal, dev-server]
- Each project has 1 active thread
- DB seeded with remote + 2 repos linked to the projects

Steps:
1. App launches and connects
2. Click repo A's thread row in sidebar → thread selected
3. Switch to Terminal mode (Cmd+2 or click segmented control)
4. Verify preset.start("terminal") sent for project A's thread
5. Verify terminal.attach sent
6. Click session tab "+" or Cmd+T → second preset starts
7. Verify preset.start("dev-server") sent for project A's thread
8. Verify second terminal.attach sent
9. Click repo B's thread row in sidebar → thread selected
10. Switch to Terminal mode
11. Verify preset.start("terminal") sent for project B's thread
12. Verify terminal.attach sent
13. Start second preset for project B
14. Verify preset.start("dev-server") sent for project B's thread
15. Verify second terminal.attach sent

Assertions:
- 4 total preset.start calls (2 per project)
- 4 total terminal.attach calls (2 per project)
- Correct thread_id in each RPC call
- Correct preset names in each call
```

### Accessibility Identifiers Required

These must exist on real interactive controls (not fake automation shims):

| Control | Identifier | Status |
|---|---|---|
| Sidebar repo section new-thread button | `repo.section.new-thread.<repo-id>` | Exists |
| Sidebar thread row | `thread.row.<thread-id>` | Exists |
| Mode picker segments | `mode.tab.chat`, `mode.tab.terminal`, etc. | Missing |
| Session tab | `session.tab.<preset-name>` | Exists |
| Session tab close | `session.tab.close.<preset-name>` | Exists |
| Session tab add (+) | `terminal.session.add` / `chat.tab.add` | Exists |
| New thread sheet | `sheet.new-thread` | Exists |
| New thread name input | `sheet.new-thread.name-input` | Exists |
| New thread submit | `sheet.new-thread.submit-button` | Exists |

The mode picker segments are the main gap. XCUITest may be able to query them by title ("Terminal", "Chat") even without explicit identifiers, since `NSSegmentedControl` segments are typically accessible. To be verified during implementation.

### Build and Run

```bash
# Build the app (SPM)
swift build --product Threadmill

# Run UI tests (Xcode)
xcodebuild test \
  -project UITests/ThreadmillUITests.xcodeproj \
  -scheme ThreadmillUITests \
  -destination 'platform=macOS'
```

Wrapped in Taskfile:

```yaml
test:ui:
  desc: Run XCUITest E2E tests
  cmds:
    - swift build --product Threadmill
    - xcodebuild test -project UITests/ThreadmillUITests.xcodeproj -scheme ThreadmillUITests -destination 'platform=macOS'
```

## Edge Cases & Error Handling

- **App fails to launch**: Test should fail fast with clear message about missing `.app` bundle
- **Mock server port conflict**: Use port 0 (OS-assigned random port) — already implemented
- **App doesn't connect within timeout**: Fail with "session.hello not received within N seconds"
- **Stale DB from previous test run**: Each test uses a unique temp directory, cleaned up in tearDown
- **Multiple Threadmill instances**: Each test launches its own isolated instance with unique DB and port
- **App steals keyboard focus**: Use `XCUIApplication` element queries instead of raw CGEvent posting

## Testing Strategy

- The validation test case IS the test
- Unit tests for `MockSpindleServer` and DB seeding helpers are optional but useful
- Future tests follow the same pattern: launch app, seed state, drive UI, verify RPCs

## Out of Scope

- Converting the app build from SPM to Xcode
- Unit tests (stay in SPM `Tests/ThreadmillTests/`)
- Spindle daemon tests (stay on beast)
- Custom AX driver / `AXTestClient` (removed, replaced by XCUITest)
- Fake automation controls (removed permanently)

## Open Questions

1. Can XCUITest query `NSSegmentedControl` segments by title inside a `NavigationSplitView` toolbar? If not, we fall back to keyboard shortcuts for mode switching and add identifiers.
2. Should `MockSpindleServer` be extracted into a shared SPM library target so both unit tests and UI tests can use it without copying? Probably yes if it grows.
