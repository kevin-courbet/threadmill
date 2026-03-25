---
name: threadmill-debugging
description: Debug Threadmill (macOS visor) and Spindle (Rust daemon) issues across the full stack — SSH tunnel, WebSocket, terminal relay, UI accessibility, and test failures. This skill should be used when investigating crashes, connection failures, test failures, UI element misidentification, or any runtime misbehavior in the Threadmill/Spindle system.
---

# Threadmill Debugging

Systematic procedures for debugging failures across the Threadmill stack: macOS app (Swift/SwiftUI), SSH tunnel, WebSocket JSON-RPC, Spindle daemon (Rust), terminal relay, and XCUI e2e tests.

## When to use this skill

- Test failure (unit, integration, or UI e2e)
- Connection/reconnection issues
- Terminal not rendering or stuck on "connecting"
- UI element not found or wrong element clicked
- Spindle RPC errors or timeouts
- Binary frame routing issues (terminal or ACP agent)
- Build failures after Spindle or protocol changes

## Diagnostic hierarchy

Always work top-down. Most bugs are in the highest layer that changed:

```
Layer 5: UI (SwiftUI views, accessibility identifiers, XCUI queries)
Layer 4: State (AppState event handling, GRDB sync, tab state)
Layer 3: Transport (ConnectionManager, TerminalMultiplexer, AgentSessionManager)
Layer 2: Wire (WebSocket JSON-RPC, binary frames, SSH tunnel)
Layer 1: Daemon (Spindle RPC handlers, tmux, worktrees, file service)
```

Identify the failing layer first, then drill down. Do NOT shotgun-debug across layers.

---

## 1. Logging System

All production logging uses `os.Logger` (subsystem `dev.threadmill`). Categories in `Sources/Threadmill/Support/Log.swift`:

| Logger | Category | What it covers |
|---|---|---|
| `Logger.boot` | `boot` | App bootstrap, lifecycle |
| `Logger.state` | `state` | AppState: selection, events, attach flow |
| `Logger.conn` | `conn` | ConnectionManager: connect/disconnect/reconnect |
| `Logger.tunnel` | `tunnel` | SSH tunnel lifecycle |
| `Logger.sync` | `sync` | SyncService: daemon -> GRDB sync |
| `Logger.mux` | `mux` | TerminalMultiplexer: channel dispatch |
| `Logger.relay` | `relay` | RelayEndpoint: PTY shim, binary frames |
| `Logger.ghostty` | `ghostty` | GhosttySurfaceHost: surface create/free |
| `Logger.agent` | `agent` | AgentSessionManager: ACP sessions |
| `Logger.browser` | `browser` | BrowserSessionManager: tab CRUD |
| `Logger.github` | `github` | GitHub OAuth device flow |
| `Logger.view` | `view` | View-layer tracing (mode switching, restore) |

### Reading logs

**Console.app** (running app):
```
Filter: subsystem:dev.threadmill
Narrow: subsystem:dev.threadmill category:conn
Enable: Action -> Include Info/Debug Messages
```

**Integration tests**: `IntegrationTestCase` auto-dumps all `dev.threadmill` logs on failure via `OSLogStore`. No action needed — logs appear in `swift test --verbose` output.

**UI e2e tests**: XCUI runs in a separate process. `OSLogStore` cannot capture cross-process logs. Use Console.app filtered to `subsystem:dev.threadmill` while reproducing.

**Spindle daemon logs**:
```bash
task spindle:logs                    # tail journalctl
ssh beast "journalctl --user -u spindle -n 200 --no-pager"  # last 200 lines
```

### Log levels

| Level | Meaning |
|---|---|
| `.debug` | Verbose, only visible with explicit filter |
| `.info` | Lifecycle transitions, state changes |
| `.notice` | Noteworthy but expected (e.g. "CONNECTED") |
| `.error` | Recoverable failures (RPC errors, attach failures) |
| `.fault` | Unrecoverable / invariant violations |

### Adding temporary debug logging

```swift
Logger.conn.debug("DEBUG: wsState=\(self.state, privacy: .public) sessionReady=\(self.sessionReady)")
```

Use `privacy: .public` for identifiers. Remove debug logging before committing.

**BANNED in Sources/**: `NSLog(...)`, `print(...)`. Enforced by pre-commit hook and `task lint`.

---

## 2. Connection Debugging

### Symptom: app stuck on "connecting"

Triage sequence:

1. **SSH tunnel**: `nc -z 127.0.0.1 19990` — if this fails, tunnel is down
2. **Spindle status**: `ssh beast "systemctl --user is-active spindle"` — must return `active`
3. **WebSocket handshake**: filter Console.app `category:conn` — look for `ping -> pong -> CONNECTED`
4. **Session negotiation**: look for `session.hello` response in conn logs

```bash
# Quick connectivity check
nc -z 127.0.0.1 19990 && echo "tunnel OK" || echo "tunnel DOWN"
ssh beast "systemctl --user is-active spindle"
```

### Symptom: reconnect loop

Filter `category:conn`. The reconnect flow:
```
transport dropped -> disconnected -> exponential backoff -> reconnect attempt N
-> tunnel start -> ws connect -> ping -> session.hello -> CONNECTED
```

Common causes:
- **Stale Spindle binary**: rebuilt but not restarted. Fix: `task spindle:restart`
- **Tunnel process zombie**: `pkill -f "ssh.*19990"` then retry
- **Beast unreachable**: `ssh beast "echo ok"` — SSH key/network issue

### Symptom: RPC timeout

1. Check conn logs for the request being sent
2. Check Spindle logs (`task spindle:logs`) for the request being received
3. If Spindle received but didn't respond: bug in Spindle RPC handler
4. If Spindle didn't receive: WebSocket frame lost (tunnel issue)

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `THREADMILL_HOST` | `beast` | SSH host for tunnel |
| `THREADMILL_DAEMON_PORT` | `19990` | Spindle WebSocket port |
| `THREADMILL_DISABLE_SSH_TUNNEL` | (unset) | Set to `1` to skip tunnel (direct connect) |

---

## 3. Terminal Debugging

### Data path

```
ghostty surface <-> PTY <-> threadmill-relay <-> Unix socket <-> WebSocket <-> Spindle <-> tmux pane
```

Binary frames: `[u16be channel_id][raw terminal bytes]`. NOT JSON.

### Symptom: terminal blank / no content

1. **channel_id acquired?** Filter `category:mux` — look for `terminal.attach` response with `channel_id`
2. **Binary frames arriving?** Filter `category:relay` — look for BUFFERING/WRITE entries
3. **Relay endpoint connected?** Filter `category:relay` — look for socket lifecycle events
4. **Ghostty surface created?** Filter `category:ghostty` — look for surface create callback
5. **tmux pane alive?** `ssh beast "tmux list-panes -t tm_<session_name>"`

### Symptom: terminal stuck on "connecting"

The `terminal.connecting` state label is shown when attach is pending. Check:
1. `terminal.attach` RPC sent (mux logs)
2. RPC response received with valid `channel_id`
3. `RelayEndpoint` created and socket path established
4. `threadmill-relay` process spawned

### Pre-registration buffering

Binary frames arriving before `terminal.attach` completes are buffered by `TerminalMultiplexer` and flushed on endpoint registration. If frames are lost, check for buffer overflow in mux logs.

---

## 4. UI & Accessibility Debugging

### CRITICAL: Accessibility identifier structure

Threadmill uses accessibility identifiers with a specific element-type mapping. **Getting this wrong is the #1 cause of UI test failures.**

| Identifier pattern | Element type | What it is |
|---|---|---|
| `session.tab.<sessionID>` | AXButton | **Close button** (xmark) on the tab |
| `session.tab.<sessionID>` | AXStaticText | Tab **label** text |
| `session.tab.<sessionID>` | AXImage | Tab **icon** |
| `session.tab.close.<sessionID>` | AXButton | Explicit close button (if present) |

**The AXButton with `session.tab.terminal-1` is the CLOSE button, not the clickable tab area.** To click/select a tab, target the `AXStaticText` with the same identifier:

```swift
// WRONG — clicks the close button
let tab = h.app.descendants(matching: .any)
    .matching(identifier: "session.tab.terminal-1").firstMatch
tab.click()  // closes the tab!

// CORRECT — clicks the label text to select the tab
let tab = h.app.staticTexts
    .matching(identifier: "session.tab.terminal-1").firstMatch
tab.click()  // selects the tab
```

### Dumping accessibility tree

When an element can't be found or the wrong element is clicked, dump the AX tree:

```swift
// In a test: dump all matching elements with their roles
let matches = h.app.descendants(matching: .any)
    .matching(NSPredicate(format: "identifier CONTAINS 'session.tab'"))
for i in 0..<matches.count {
    let el = matches.element(boundBy: i)
    print("[\(i)] role=\(el.elementType.rawValue) id=\(el.identifier) label=\(el.label) value=\(el.value ?? "nil")")
}
```

From outside the test process (standalone script):
```swift
// Walk the AXUIElement tree filtering by identifier prefix
func walk(_ element: AXUIElement, depth: Int = 0) {
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    guard let childArray = children as? [AXUIElement] else { return }
    for child in childArray {
        var id: CFTypeRef?, role: CFTypeRef?
        AXUIElementCopyAttributeValue(child, "AXIdentifier" as CFString, &id)
        AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
        let idStr = id as? String ?? ""
        if idStr.contains("session.tab") {
            print("\(String(repeating: "  ", count: depth))\(role as? String ?? "") id=\(idStr)")
        }
        walk(child, depth: depth + 1)
    }
}
```

### Identifier reference

Full list in `docs/agents/ui-e2e-tests.md`. Key ones:

**Sidebar**: `thread.row.<threadID>`, `project.section.new-thread.<projectID>`
**Mode switcher**: `mode.tab.{chat,terminal,files,browser}`
**Terminal**: `terminal.surface`, `terminal.connecting`, `terminal.session.add`, `terminal.session.add.menu`, `terminal.session.add.item.<name>`
**Session tabs**: `session.tab.<sessionID>`, `session.tab.close.<sessionID>`
**Chat**: `chat.session.add`

### Filtering XCUI queries to avoid ambiguity

When an identifier is shared across multiple element types (button, text, image), always scope the query:

```swift
// Scope by element type
h.app.staticTexts.matching(identifier: "session.tab.terminal-1")
h.app.buttons.matching(identifier: "session.tab.close.terminal-1")

// Exclude close buttons when finding tabs
h.app.descendants(matching: .any).matching(NSPredicate(format:
    "identifier BEGINSWITH 'session.tab.terminal-' AND NOT identifier BEGINSWITH 'session.tab.close.'"
))
```

---

## 5. Test Debugging

### Unit tests (Layer 4-5)

```bash
task test:swift                # all unit tests
swift test --filter <TestClass>  # single class
swift test --filter <TestClass>/<testMethod>  # single method
```

Uses mock doubles from `Tests/ThreadmillTests/Shared/TestDoubles.swift`. DI via protocols in `Support/Abstractions.swift`. All test classes are `@MainActor`.

### Integration tests (Layer 1-3)

```bash
task test:integration          # all integration tests
swift test --filter IntegrationTests --verbose
```

**Prerequisites**: beast reachable, Spindle running, SSH tunnel on :19990. `task test:integration` handles all of this.

**Log capture**: `IntegrationTestCase` auto-dumps `dev.threadmill` os.Logger output on failure. Manual dump in test body:

```swift
dumpLogs()                     // all categories
dumpLogs(category: "conn")     // specific category
```

**Thread cleanup**: test threads use `test-` prefix. Stale threads are swept on first run per suite.

### UI e2e tests (Layer 5)

```bash
task test:ui                   # all e2e tests
task test:ui -- -only-testing:ThreadmillUITests/TerminalE2ETests/test01_TerminalShowsPromptWithoutInteraction
```

**Prerequisites**: SSH tunnel, Spindle running, fixture thread (`test-xcui-*`), Accessibility permission for Terminal. `task test:ui` handles everything except Accessibility.

**Debugging failures**: XCUI runs out-of-process. Cannot use OSLogStore. Instead:
1. Open Console.app, filter `subsystem:dev.threadmill`
2. Reproduce the scenario manually or re-run the failing test
3. Capture screenshots in the test: `h.screenshot(name: "debug", testCase: self)`

### Spindle tests (Layer 1)

```bash
task test:spindle              # run on beast via SSH
ssh beast "cd /home/wsl/dev/spindle && cargo test -- --nocapture"  # with stdout
ssh beast "cd /home/wsl/dev/spindle && cargo test <test_name>"     # single test
```

---

## 6. Spindle Daemon Debugging

### Status and logs

```bash
task spindle:status            # is-active + full status
task spindle:logs              # tail journalctl -f
ssh beast "journalctl --user -u spindle -n 200 --no-pager"
```

### Restart after rebuild

**CRITICAL**: After rebuilding Spindle, the daemon MUST be restarted. A stale daemon running a deleted binary causes silent failures.

```bash
task spindle:restart           # build + systemctl restart + status check
```

### Common Spindle issues

| Symptom | Likely cause | Fix |
|---|---|---|
| RPC returns stale data | Stale daemon binary | `task spindle:restart` |
| `thread.create` hangs | tmux server down | `ssh beast "tmux start-server"` |
| `terminal.attach` fails | Thread not active | Wait for `thread.status_changed -> active` |
| `file.list` authorization error | Path outside known project | Check `project.add` was called |
| Binary frames not arriving | pipe-pane not set up | Check Spindle logs for tmux errors |

### Inspecting daemon state directly

```bash
# List threads from daemon's perspective
ssh beast 'echo '"'"'{"jsonrpc":"2.0","id":1,"method":"thread.list","params":{}}'"'"' | websocat ws://127.0.0.1:19990'

# Check threads.json state file
ssh beast "cat /home/wsl/.config/spindle/threads.json | python3 -m json.tool"

# List tmux sessions
ssh beast "tmux list-sessions"
```

---

## 7. Build Debugging

### Swift build failures

```bash
task build                     # swift build
swift build 2>&1 | head -50    # first errors only
```

Common after protocol changes: types in `protocol/threadmill-rpc.schema.json` changed but Swift models not updated. Check `Sources/Threadmill/Models/` matches the schema.

### Spindle build failures

```bash
task build:spindle             # cargo build on beast
ssh beast "cd /home/wsl/dev/spindle && cargo build 2>&1"
```

Edit Spindle files locally at `spindle/` (symlink to `/Volumes/wsl-dev/spindle/`, gitignored). Build via SSH.

### Full validation

```bash
task validate                  # build:all + test (full gate)
```

---

## 8. Common Failure Patterns

### "Fixture thread not found in sidebar"

UI e2e test can't find the `test-xcui-*` thread. Causes:
1. Spindle not running: `ssh beast "systemctl --user is-active spindle"`
2. Fixture not created: `swift Scripts/setup_xcui_fixture.swift`
3. Sync not completed: app needs time after launch to sync. Harness waits 10s.
4. Thread was closed/hidden: re-run fixture setup

### "terminal.surface never appeared"

1. Check mode switched to terminal (mode.tab.terminal clicked)
2. Check `terminal.attach` RPC succeeded (conn logs)
3. Check `RelayEndpoint` was created (relay logs)
4. Check `threadmill-relay` process spawned (ghostty logs)

### "ACP initialize failed"

Agent session handshake broken:
1. Check `agent.start` returned valid `channel_id`
2. Check agent process running on beast: `ssh beast "pgrep -la opencode"`
3. Check binary frames being relayed (agent category logs)
4. Check ACP protocol version compatibility

### XCUI strict mode violation

Playwright-style error when a locator matches multiple elements:
```
Multiple matches found for...
```

Fix: scope by element type (`staticTexts`, `buttons`) or add `NOT identifier BEGINSWITH` exclusions. See Section 4.

---

## 9. Debugging Checklist

For any bug, run through this before diving into code:

- [ ] Which layer failed? (UI / State / Transport / Wire / Daemon)
- [ ] Can you reproduce with `task test:swift` or `task test:integration`?
- [ ] Are Console.app logs showing the expected flow?
- [ ] Is Spindle running and reachable? (`task spindle:status`)
- [ ] Was Spindle rebuilt but not restarted?
- [ ] Is the SSH tunnel up? (`nc -z 127.0.0.1 19990`)
- [ ] For UI issues: did you dump the accessibility tree to verify element types?
- [ ] For protocol issues: does the JSON schema match the Swift/Rust types?
