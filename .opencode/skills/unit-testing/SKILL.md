---
name: unit-testing
description: Enforce unit testing standards before writing or reviewing tests. Use whenever creating, modifying, or reviewing Swift unit tests in Threadmill.
---

# Unit Testing Standards

Read `docs/agents/unit-testing.md` for the full testing policy.

## Non-negotiables

1. **Never write source-reading tests.** If you catch yourself using `String(contentsOf:)` to read a `.swift` file and assert on its string contents — stop. That is not a test.
2. **Never write trivially shallow tests.** Don't test struct init field assignment, mock recording, or anything the compiler already enforces.
3. **Every test must verify behavior** — a state transition, error path, protocol contract, or business logic edge case.
4. **One behavior per test.** Multiple behaviors = multiple tests.
5. **Run `task test:swift` after writing tests.** All tests must pass.
