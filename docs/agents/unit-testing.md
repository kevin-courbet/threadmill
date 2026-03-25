---
updated: 2026-03-25
---

# Unit Testing Standards

## STOP — Before Writing Any Test

If you are about to write a unit test, ask: **does this test verify behavior, or does it verify that source code contains certain strings?**

If the answer is the latter, **do not write the test**. It is worse than no test — it creates maintenance burden, false confidence, and breaks on every rename.

## Banned Patterns

### Source-reading tests (zero tolerance)

Never read `.swift` source files and assert on their string contents:

```swift
// BANNED — this tests nothing
let source = try String(contentsOf: somePath)
XCTAssertTrue(source.contains("@Environment(SomeManager.self)"))
```

This pattern:
- Tests that characters exist in a file, not that code works
- Breaks on any rename, reformat, or refactor
- Catches nothing the compiler doesn't already enforce
- Provides zero confidence that the feature actually works

If you feel the urge to write one, the real test is either:
- A **behavioral unit test** that exercises the logic
- A **UI e2e test** that verifies the feature works end-to-end
- **Not needed at all** because the compiler already enforces it

### Trivially shallow tests

Do not test that a struct initializer sets the fields you passed in:

```swift
// BANNED — the compiler enforces this
func testProjectHasName() {
    let p = Project(name: "foo")
    XCTAssertEqual(p.name, "foo")
}
```

Do not test that a mock recorded a call (tests the mock, not production code):

```swift
// BANNED — tests the test infrastructure
func testMockRecordsCalls() {
    mock.doSomething()
    XCTAssertTrue(mock.doSomethingCalled)
}
```

### Over-mocked tests

If a test requires 5+ mock setup lines to verify one trivial property, the test is testing wiring, not behavior. Either:
- Test at a higher level where the wiring is exercised naturally
- Don't test it — the compiler and integration tests cover wiring

## What Makes a Good Unit Test

A good unit test exercises **one behavioral scenario** and verifies the **outcome**, not the implementation:

1. **State transitions** — given state A, when event X, then state B
2. **Error paths** — given bad input, the correct error is surfaced (not swallowed)
3. **Protocol contracts** — conformance produces correct results
4. **Edge cases** — boundary values, empty collections, race conditions
5. **Business logic** — calculations, filtering, sorting, mapping with non-trivial rules

### Structure: Arrange → Act → Assert

```swift
func testAttachRetryCancelsOnPermanentError() {
    // Arrange: set up state with a pending attach
    let state = AppState(...)
    state.pendingAttach = .retry(presetName: "editor")

    // Act: deliver a permanent tmux error event
    state.handleEvent(.threadProgress(.tmuxError("pane dead")))

    // Assert: retry was cancelled, status reflects failure
    XCTAssertNil(state.pendingAttach)
    XCTAssertEqual(state.selectedThread?.status, .failed)
}
```

### Naming

Test names should describe the scenario, not the method:

```swift
// Good — describes behavior
func testCloseThreadCancelsAttachAndRemovesTerminalSessions()
func testReconnectRemapsAllChannelIDs()

// Bad — describes method call
func testHandleEvent()
func testInit()
```

## Test Organization

| Directory | Purpose | Runner |
|---|---|---|
| `Tests/ThreadmillTests/Unit/` | Behavioral unit tests with mock doubles | `task test:swift` |
| `Tests/ThreadmillTests/Integration/` | Real Spindle integration tests | `task test:integration` |
| `Tests/ThreadmillTests/Shared/` | Shared `TestDoubles.swift` | — |
| `UITests/ThreadmillUITests/` | XCUI e2e tests (Xcode project, real Spindle) | `task test:ui` |

## When NOT to Write a Unit Test

- The behavior is already covered by an integration test
- The "logic" is just passing values through (pure wiring)
- The compiler already enforces correctness (type system, exhaustive switches)
- You'd need to read source files to assert anything meaningful — that's a design smell, not a testing opportunity
