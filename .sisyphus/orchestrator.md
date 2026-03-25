# Orchestrator State

status: SPAWNING
goal_version: 1
next_worker_id: W002
active_batch_id: B001
last_integrated_commit: none

## Active Workers
- worker_id: W001
  batch_id: B001
  task: "Phase 1: Spindle protocol + params — add session_id to all RPC params, use preset for config lookup, session_id for window/target key, remove resolve_base_preset_name, update schema"
  handoff_file: /Users/kevincourbet/dev/threadmill.session-id-protocol/.sisyphus/workers/W001.md
  status: assigned

## Pending Integration
- worker_id: none
  batch_id: none
  stop_reason: none
  handoff_file: none
  status: none

## Notes
- Shared worktree mode: workers do not commit; orchestrator owns git integration.
- Two-phase task: Phase 1 = Spindle (Rust), Phase 2 = Mac (Swift). Sequential because Mac depends on protocol changes.
- Spindle source is at spindle/ symlink (→ /Volumes/wsl-dev/spindle/), edits are local, builds via SSH.
