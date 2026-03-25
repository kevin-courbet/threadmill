---
updated: 2026-03-25
---

# UI E2E Tests

End-to-end tests that launch the real Threadmill app against real Spindle on beast and interact through XCUI accessibility queries. No mocks, no DB isolation — tests use the production environment.

## Architecture

```
task test:ui
  1. pkill Threadmill (kill stale instances)
  2. swift build --product Threadmill
  3. Scripts/package_app.sh          → .build/debug/Threadmill.app
  4. Scripts/sync_xcodeproj.sh       → regenerates UITests .pbxproj
  5. ensure SSH tunnel on :19990
  6. Scripts/setup_xcui_fixture.swift → creates fixture thread on beast (idempotent)
  7. xcodebuild test                 → launches app, runs XCUI tests
```

### TestHarness

All tests share one `TestHarness` instance (one app launch per test suite).

1. Launches `Threadmill.app` via `NSWorkspace.openApplication`
2. Waits for foreground + window
3. Waits for fixture thread (`test-xcui-*`) to appear in sidebar (proves Spindle sync completed)
4. Returns `TestHarness` with the `XCUIApplication` handle

The app uses its real database — all your projects and threads are visible. Tests identify the fixture thread by its `test-xcui` name prefix.

### What tests assert on

- UI element existence/absence via accessibility identifiers
- Element state (labels, values, enabled/disabled)
- Navigation flows (click → wait → verify)
- Screenshots as evidence

### What tests should NOT assert on

- RPC payloads, call counts, binary frames → `Tests/ThreadmillTests/Integration/`
- Internal state (GRDB, AppState) → `Tests/ThreadmillTests/Unit/`

## Prerequisites

1. **SSH tunnel**: `ssh -N -f -L 127.0.0.1:19990:127.0.0.1:19990 beast`
2. **Spindle running**: `ssh beast "systemctl --user status spindle"`
3. **tmux server running**: `ssh beast "tmux start-server"` (Spindle auto-recreates dead sessions, but tmux server must be up)
4. **Fixture project**: `/home/wsl/dev/threadmill-test-fixture` on beast with `.threadmill.yml`
5. **Accessibility permission**: System Settings → Privacy & Security → Accessibility → enable Terminal

All except (5) are handled by `task test:ui`.

## Fixture

`Scripts/setup_xcui_fixture.swift` connects to Spindle and:
- Calls `project.add` for `/home/wsl/dev/threadmill-test-fixture`
- If an active `test-xcui-*` thread exists, reuses it
- Otherwise creates `test-xcui-<8chars>` and waits for `status_changed → active`

The fixture thread persists across runs. If its tmux session dies (beast reboot), Spindle auto-recreates it on next `preset.start`.

## Writing a New Test

All tests go in `ThreadmillUITests.swift` (single class, shared harness):

```swift
func testMyFeature() throws {
    let h = try ensureHarness()

    // Navigate to fixture thread
    guard let threadRow = h.waitForFixtureThread() else {
        XCTFail("Fixture thread not found")
        return
    }
    threadRow.click()

    // Switch mode
    try h.selectMode("mode.tab.terminal")

    // Wait and assert
    let surface = h.app.descendants(matching: .any)
        .matching(identifier: "terminal.surface").firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))

    // Screenshot as evidence
    h.screenshot(name: "my-feature", testCase: self)
}
```

After adding code, run `bash Scripts/sync_xcodeproj.sh`.

## Harness Helpers

| Method | Description |
|---|---|
| `TestHarness.launch()` | Launches app, waits for sync |
| `h.tearDown()` | Terminates app |
| `h.waitForFixtureThread(timeout:)` | Finds `thread.row.*` with label containing `test-xcui` |
| `h.selectMode(_:timeout:)` | Clicks a mode tab by identifier |
| `h.screenshot(name:testCase:)` | Captures window screenshot, attaches to test |

Use `h.app` (the `XCUIApplication`) for element queries:

```swift
let button = h.app.descendants(matching: .any)
    .matching(identifier: "terminal.session.add").firstMatch
button.waitForExistence(timeout: 3)
button.click()
```

## Accessibility Identifiers

### Sidebar
| Identifier | Element |
|---|---|
| `thread.row.<threadID>` | Thread row |
| `project.section.new-thread.<projectID>` | New thread button |
| `sidebar.add-repository-button` | Add repository button |

### Mode Switcher
| Identifier | Element |
|---|---|
| `mode.tab.chat` | Chat mode |
| `mode.tab.terminal` | Terminal mode |
| `mode.tab.files` | Files mode |
| `mode.tab.browser` | Browser mode |

### Terminal
| Identifier | Element |
|---|---|
| `terminal.surface` | GhosttyKit Metal terminal view |
| `terminal.connecting` | "Connecting..." state |
| `terminal.session.add` | `+` button |
| `terminal.session.add.menu` | `⌄` dropdown for named presets |
| `terminal.session.add.item.<name>` | Preset in dropdown |
| `session.tab.<sessionID>` | Session tab |
| `session.tab.close.<sessionID>` | Close button on tab |

### Chat
| Identifier | Element |
|---|---|
| `chat.session.add` | `+` button |

## Running

```bash
task test:ui                    # all tests
task test:ui -- -only-testing:ThreadmillUITests/TerminalE2ETests/test01_TerminalShowsPromptWithoutInteraction
```

## Debugging Failures

XCUI tests run in a separate process from the app. `OSLogStore` can't capture cross-process logs.

**On failure:** open Console.app, filter `subsystem:dev.threadmill`, reproduce. All structured `os.Logger` output (connection, state, sync, attach) is visible there.

## Test Layers

| Layer | Location | What it tests |
|---|---|---|
| **Unit** | `Tests/ThreadmillTests/Unit/` | Business logic with mock doubles |
| **Integration** | `Tests/ThreadmillTests/Integration/` | Wire protocol against real Spindle |
| **UI E2E** | `UITests/ThreadmillUITests/` | Full app, real UI interactions |

E2E tests verify user-visible behavior. Protocol correctness belongs in Integration tests.
