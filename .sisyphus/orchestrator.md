# Orchestrator State

status: READY
goal_version: 1
next_worker_id: W001
active_batch_id: none
last_integrated_commit: none

## Active Workers
- worker_id: none
  batch_id: none
  task: none
  handoff_file: none
  status: none

## Pending Integration
- worker_id: none
  batch_id: none
  stop_reason: none
  handoff_file: none
  status: none

## Notes
- Shared worktree mode: workers do not commit; orchestrator owns git integration.
