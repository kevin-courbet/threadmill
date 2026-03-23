---
updated: 2026-03-23
---

# UI E2E Tests

End-to-end tests that launch the real Threadmill app, connect to real Spindle on beast, and interact through XCUI accessibility queries.

## Architecture

```
task test:ui
  1. swift build --product Threadmill
  2. Scripts/package_app.sh          → .build/debug/Threadmill.app
  3. Scripts/sync_xcodeproj.sh       → regenerates UITests .pbxproj from filesystem
  4. ensure SSH tunnel on :19990
  5. Scripts/setup_xcui_fixture.swift → creates fixture thread on beast (idempotent)
  6. xcodebuild test                 → launches app, runs XCUI tests
```

### RealSpindleHarness

Every test uses `RealSpindleHarness` — no mocks, no in-process servers.

1. Creates a temp directory with a fresh GRDB database
2. Seeds the DB with a Remote pointing at `127.0.0.1:19990` (tunneled Spindle)
3. Launches `Threadmill.app` via `NSWorkspace.openApplication` with env overrides:
   - `THREADMILL_DB_PATH` → isolated temp DB (only fixture data visible)
   - `THREADMILL_DISABLE_SSH_TUNNEL=1` → app connects directly to localhost
   - `THREADMILL_HOST=127.0.0.1`, `THREADMILL_DAEMON_PORT=19990`
4. Waits for app to reach foreground + window existence + Spindle sync (3s settle)
5. Returns `RealSpindleHarness` with the `XCUIApplication` handle

### What tests can assert on

- UI element existence/absence via accessibility identifiers
- UI element state (labels, values, enabled/disabled)
- Navigation flows (click → wait → verify)
- Screenshots as evidence attachments

### What tests should NOT assert on

- RPC payloads, call counts, binary frames — that belongs in `Tests/ThreadmillTests/Integration/`
- Internal state (GRDB contents, AppState properties) — that belongs in `Tests/ThreadmillTests/Unit/`

## Prerequisites

1. **SSH tunnel**: `ssh -N -f -L 127.0.0.1:19990:127.0.0.1:19990 beast`
2. **Spindle running**: `ssh beast "systemctl --user status spindle"`
3. **Fixture project**: `/home/wsl/dev/threadmill-test-fixture` must exist on beast as a git repo with a `.threadmill.yml`
4. **Accessibility permission**: System Settings → Privacy & Security → Accessibility → enable Terminal (or your terminal app)

All of these except (4) are handled automatically by `task test:ui`.

## Fixture

`Scripts/setup_xcui_fixture.swift` connects to Spindle and:
- Calls `project.add` for `/home/wsl/dev/threadmill-test-fixture`
- Checks if an active thread already exists (idempotent)
- If not, creates `test-xcui-<8chars>` thread and waits for `status_changed → active`

The fixture thread persists on beast between runs. Tests find it via:
```swift
// Matches sidebar rows whose identifier starts with "thread.row."
// and whose label contains "test-xcui"
harness.waitForFixtureThread(timeout: 10)
```

## Writing a New Test

```swift
import Foundation
import XCTest

@MainActor
final class MyFeatureTests: XCTestCase {
    private var harness: RealSpindleHarness?

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try RealSpindleHarness.launch()
    }

    override func tearDownWithError() throws {
        harness?.tearDown()
        harness = nil
        try super.tearDownWithError()
    }

    func testMyFeature() throws {
        guard let harness else { throw XCTSkip("Harness not available") }

        // 1. Find and click the fixture thread
        guard let threadRow = harness.waitForFixtureThread() else {
            XCTFail("Fixture thread not found")
            return
        }
        threadRow.click()

        // 2. Navigate to the mode you're testing
        try harness.selectMode("mode.tab.terminal")  // or .chat, .files, .browser

        // 3. Wait for elements and assert
        let surface = harness.app.descendants(matching: .any)
            .matching(identifier: "terminal.surface").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 10))

        // 4. Take screenshots as evidence
        harness.screenshot(name: "my-feature-result", testCase: self)
    }
}
```

After adding the file, run `bash Scripts/sync_xcodeproj.sh` to update the Xcode project.

## Harness Helpers

| Method | Description |
|---|---|
| `RealSpindleHarness.launch()` | Seeds fresh DB, launches app, waits for sync |
| `harness.tearDown()` | Terminates app, deletes temp directory |
| `harness.waitForFixtureThread(timeout:)` | Finds `thread.row.*` with label containing `test-xcui` |
| `harness.selectMode(_:timeout:)` | Clicks a mode tab by identifier |
| `harness.screenshot(name:testCase:)` | Captures window screenshot, attaches to test |

For element interaction, use `harness.app` (the `XCUIApplication`) directly:

```swift
// Wait for element
let button = harness.app.buttons.matching(identifier: "terminal.session.add").firstMatch
XCTAssertTrue(button.waitForExistence(timeout: 5))

// Click
button.click()

// Query by label
let tab = harness.app.descendants(matching: .any)
    .matching(NSPredicate(format: "label CONTAINS 'dev-server'")).firstMatch

// Type text (for input fields)
let textField = harness.app.textFields["my-input"].firstMatch
textField.click()
textField.typeText("hello")
```

## Available Accessibility Identifiers

### Sidebar
| Identifier | Element |
|---|---|
| `thread.row.<threadID>` | Thread row |
| `project.section.new-thread.<projectID>` | New thread button in project |
| `sidebar.add-repository-button` | Add repository toolbar button |

### Mode Switcher
| Identifier | Element |
|---|---|
| `mode.tab.chat` | Chat mode tab |
| `mode.tab.terminal` | Terminal mode tab |
| `mode.tab.files` | Files mode tab |
| `mode.tab.browser` | Browser mode tab |

### Terminal
| Identifier | Element |
|---|---|
| `terminal.surface` | GhosttyKit Metal terminal view |
| `terminal.connecting` | "Connecting..." spinner text |
| `terminal.session.add` | `+` button to create new terminal |
| `terminal.session.add.menu` | `⌄` dropdown for named presets |
| `terminal.session.add.item.<name>` | Named preset in dropdown (e.g. `dev-server`) |
| `session.tab.<sessionID>` | Session tab capsule |
| `session.tab.close.<sessionID>` | Close button on session tab |

### Chat
| Identifier | Element |
|---|---|
| `chat.session.add` | `+` button to create new chat |

### New Thread Sheet
| Identifier | Element |
|---|---|
| `sheet.new-thread` | The sheet |
| `sheet.new-thread.name-input` | Thread name field |
| `sheet.new-thread.submit-button` | Create button |
| `sheet.new-thread.cancel-button` | Cancel button |

## Running

```bash
task test:ui
```

Or to run a single test:
```bash
task test:ui -- -only-testing:ThreadmillUITests/TerminalPromptTests/testNewTerminalShowsPromptWithoutEnterPress
```

## Relationship to Other Test Layers

| Layer | Location | What it tests |
|---|---|---|
| **Unit** | `Tests/ThreadmillTests/Unit/` | Business logic with mock doubles |
| **Integration** | `Tests/ThreadmillTests/Integration/` | Wire protocol against real Spindle |
| **UI E2E** | `UITests/ThreadmillUITests/` | Full app launch, real UI interactions |

E2E tests verify **user-visible behavior** — "does the terminal surface appear?", "do session tabs show up?". Protocol correctness ("did we send the right RPC params?") belongs in Integration tests.
