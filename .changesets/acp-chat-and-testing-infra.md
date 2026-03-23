# Handover Document

**Commit:** c26f2f3
**Started:** 2026-03-22

## Changeset Overview

Replaced the entire chat backend (opencode serve HTTP/SSE → ACP protocol over Spindle binary relay) and rebuilt the chat UI with Aizen-quality rendering. Then built a comprehensive three-layer testing infrastructure (SPM protocol tests, AppStack tests, XCUI e2e tests) against real Spindle on beast, upgraded to Swift 6 strict concurrency, and removed the dead OpenCode dependency. Currently in RED state on a terminal prompt TDD bug fix.

## Key Changes

### ACP Chat (PR #9, merged to main)
- `Sources/Threadmill/Transport/AgentSessionManager.swift` — ACP transport: binary frame deframing, JSON-RPC routing, session lifecycle, reconnect, auto-approve `request_permission`
- `Sources/Threadmill/Models/TimelineItem.swift`, `ToolCallGroup.swift` — Timeline data model with exploration clustering
- `Sources/Threadmill/Features/Chat/ChatSessionView.swift`, `ChatInputBar.swift`, `ChatMessageList.swift` — Rebuilt chat UI with agent/mode selectors, virtual window
- `Sources/Threadmill/Features/Chat/ToolCallView.swift`, `CodeBlockView.swift`, `MarkdownView.swift` — Rich rendering with tree-sitter highlighting
- `Sources/Threadmill/Views/Components/AnimatedGradientBorder.swift`, `ShimmerEffect.swift` — Visual polish
- `protocol/threadmill-rpc.schema.json` — Added agent.start/stop/status_changed
- Spindle (`/home/wsl/dev/spindle/src/services/agent.rs`) — ACP agent process management on beast

### Testing Infrastructure
- `Tests/ThreadmillTests/Integration/Protocol/` — 7 tests against real Spindle (project, thread, terminal, preset, ACP chat, terminal prompt)
- `Tests/ThreadmillTests/Integration/Protocol/SpindleConnection.swift` — Lightweight WebSocket client for test harness
- `Tests/ThreadmillTests/Integration/Protocol/IntegrationTestCase.swift` — Base class with fixture management
- `UITests/ThreadmillUITests/RealSpindleHarness.swift` — XCUI harness: fresh DB with seeded Remote, NSWorkspace app launch, fixture thread from Spindle
- `UITests/ThreadmillUITests/TerminalPromptTests.swift` — RED: reproduces terminal prompt bug
- `UITests/ThreadmillUITests/SimpleSpindleClient.swift` — Minimal WebSocket client for XCUI fixture setup
- `Scripts/setup_xcui_fixture.swift` — Creates fixture thread on Spindle before XCUI tests
- `Scripts/sync_xcodeproj.sh` — Auto-generates Xcode project source file list from filesystem
- `Tests/ThreadmillTests/Integration/README.md` — Full procedure docs for all test layers

### Swift 6 + Cleanup
- `Package.swift` — `swift-tools-version: 6.0`, strict concurrency
- Removed `OpenCodeClient.swift`, `OpenCodeManaging.swift`, `OpenCodeModels.swift`, `MockOpenCodeClient`
- `ChatConversationService.swift` — Removed dead `openCodeClient` dependency and `directory` parameter
- `GhosttyNSView.swift` — Added accessibility: role=textArea, identifier=terminal.surface, value=terminal text buffer
- `RelayEndpoint.swift` — Accumulates last 8KB terminal output for accessibility

### Beast / Spindle
- `/home/wsl/dev/spindle/src/services/agent.rs` — New: spawn ACP agents, relay stdin/stdout as binary frames
- `/home/wsl/dev/spindle/src/services/thread.rs` — Fixed pre-existing thread cancellation test race
- `/home/wsl/dev/threadmill-test-fixture/` — Dedicated test fixture repo (cloned from myautonomy) with `.threadmill.yml`

## Current Status

**Complete:**
- ACP chat integration (all 6 phases + review fixes, merged)
- SPM integration tests (7 tests, all passing, 12s)
- Swift 6 strict concurrency (0 errors in both SPM and Xcode)
- XCUI harness working (app launches, connects to real Spindle, fixture DB isolated)
- Test directory structure: `Unit/`, `Integration/Protocol/`, `Integration/AppStack/`, `UITests/`
- Docs and sync scripts

**In Progress — RED state (TDD):**
- Terminal prompt bug: new terminal shows "Last login" + "You have mail" but no prompt until Enter is pressed
- XCUI test confirms: terminal stuck in "connecting" state (the `terminal.connecting` accessibility ID is visible, `terminal.surface` never appears)
- Root cause identified: `AppState.attachPreset()` silently returns at line 572 (`presets.contains` guard fails) because the fixture project's presets aren't populated in `appState.presets` when the app launches with a fresh DB
- The protocol-level test (TerminalPromptTests in Integration/Protocol) PASSES — Spindle sends the data correctly. The bug is Mac-side.

**Not started:**
- AppStack integration tests (placeholder `AppStackTestCase.swift` exists, no tests yet)
- Fixing the existing mock-based XCUI tests (broken by macOS Sequoia NWListener sandbox change)

## Next Steps

1. **GREEN the terminal prompt bug** — Fix the preset sync so `appState.presets` is populated when the app launches with a fresh DB and syncs from Spindle. The `project.list` response includes presets; verify `SyncService` stores them and `AppState` reads them before `attachPreset` is called. The fix is likely in `SyncService` or `AppState.onConnected` ordering.

2. **Verify XCUI terminal.surface accessibility** — Once attach succeeds, confirm `GhosttyNSView` is visible to XCUI via the `accessibilityIdentifier("terminal.surface")` + `accessibilityValue()` returning `RelayEndpoint.terminalText`. If XCUI still can't find it, the `CAMetalLayer`-backed view may need additional accessibility work.

3. **Assert prompt content** — Read `terminalView.value` (the stripped terminal text buffer) and assert it contains a prompt character without pressing Enter.

4. **REFACTOR** — Clean up the test, remove debug scaffolding, commit GREEN.

5. **Push all commits** — 13 commits ahead of origin/main.

## Integration Notes

- **13 unpushed commits on main** — these include the merged ACP PR plus all testing infrastructure. Push when ready.
- **Spindle changes are on beast** — `agent.rs` and thread cancellation fix are live on beast but not committed to Spindle's git. Need to commit on beast separately.
- **Fixture repo on beast** — `/home/wsl/dev/threadmill-test-fixture` must exist for integration tests. Created by cloning myautonomy + adding `.threadmill.yml`.
- **SSH tunnel required** — All integration and XCUI tests need `ssh -N -f -L 127.0.0.1:19990:127.0.0.1:19990 beast`. `task test:integration` handles this automatically; `task test:ui` also handles it.
- **XCUI tests are opt-in** — They do NOT run with `task test:swift` or `task validate`. Only via `task test:ui` or direct xcodebuild invocation.
- **sync_xcodeproj.sh must run after adding Swift files** — The Xcode project for UITests needs regeneration. `task test:ui` runs it automatically.
- **Existing mock XCUI tests are broken** — `MockSpindleServer` uses `NWListener` which macOS Sequoia blocks in sandboxed test runners. Unrelated to our changes. The real-Spindle XCUI tests (`RealSpindleHarness`) bypass this entirely.
