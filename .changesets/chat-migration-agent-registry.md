# Handover Document

**Commit:** e54b3f0 (Swift), f75a41b (Spindle)
**Started:** 2026-04-01

## Changeset Overview

Migrated the chat system from the obsolete `agent.start` client-side ACP path to Spindle's server-managed `chat.*` RPCs (`chat.start`/`chat.attach`/`chat.stop`). Added an agent registry system where Spindle discovers installed agent binaries via `which` and broadcasts availability to the Mac. Added a Settings > Agents UI with install buttons.

## Key Changes

### Swift app
- `Transport/AgentSessionManager.swift`: Full rewrite — uses `chat.start` + `chat.attach` RPCs instead of `agent.start` + client-side ACP handshake. Spindle manages ACP lifecycle. Session ID rewriting is transparent.
- `Support/Abstractions.swift`: Removed `AgentManaging` protocol.
- `Transport/ConnectionManager.swift`: Removed `AgentManaging` extension (`startAgent`/`stopAgent`).
- `App/AppDelegate.swift`: Simplified — no more `AgentManaging` cast.
- `App/AppState.swift`: Removed `startAgent`/`stopAgent`/`handleAgentStatusChanged`. Added `agentRegistry: [AgentRegistryEntry]` and `installAgent(agentID:)`.
- `Models/AgentConfig.swift`: Added `AgentRegistryEntry`, `AgentInstallMethod` models.
- `Features/Chat/ChatSessionViewModel.swift`: Added `configOptionUpdate` handling (populates model selector), `agentThoughtChunk` handling.
- `Features/Threads/ChatModeContent.swift`: Agent selector uses `agentRegistry.filter(\.installed)` instead of `Project.agents`.
- `Database/SyncService.swift`: Fetches `agent.registry.list` during sync.
- `Features/Settings/AgentsSettingsView.swift`: New — shows agent availability per remote with install buttons.
- `Features/Settings/SettingsView.swift`: Added Agents section.

### Spindle (Rust daemon)
- `src/services/agent_registry.rs`: New — 8 built-in agent catalog, `which`-based discovery, `npm`/`uv` install.
- `src/protocol.rs`: Added `AgentRegistryListParams`, `AgentRegistryInstallParams`, `AgentRegistryInstallResult`. Extended `ChatAttachResult` with `modes`/`models`/`config_options`. Extended `StateSnapshot` with `agent_registry`.
- `src/rpc_router.rs`: Added `agent.registry.list` and `agent.registry.install` RPC handlers.
- `src/services/chat.rs`: Store `modes`/`models`/`config_options` from ACP handshake in `ChatSessionRuntime`, return from `chat.attach`.
- `src/services/project.rs`: Added `default_agents()` fallback when `.threadmill.yml` has no agents.

### Tests
- Rewrote `AgentSessionManagerTests` for `chat.*` flow (6 tests).
- Updated `IntegrationFlowTests`, `ChatModeContentTests`, `SyncServiceTests`, `AppStateRemoteConnectionTests`.
- Removed `MockAgentManager` from `TestDoubles.swift`.
- All 159 tests pass.

## Current Status

**Complete:**
- Chat migration to `chat.*` RPCs — binary frame handling unchanged, handshake moved to Spindle
- Agent registry discovery + broadcast + Settings UI
- `configOptionUpdate` → model selector population
- `agentThoughtChunk` → thought text display

**In progress / Needs fixing (from review):**

### Three UI bugs (user-reported)
1. **Agent replies concatenated into one bubble** — `streamingAgentMessageID` is a `let` constant (`"streaming-agent"`). Every turn's chunks append to the same message. Fix: make it `var`, generate new UUID per turn in `finishStreamingCycle`.
2. **User messages not showing** — Same issue: `streamingUserMessageID = "streaming-user"` is constant. All user messages merge into one. Same fix.
3. **Session switch clears messages** — `ChatSessionViewModelCache` only caches ONE viewmodel. Switching conversations drops the previous. Fix: use a dictionary cache keyed by conversationID.

### Review findings (from GPT 5.4 + Opus 4.6 parallel review)

**Critical:**
- `discover_agents()` blocks tokio thread — 8 synchronous `which` calls. Fix: `tokio::task::spawn_blocking`.
- `install_agent` blocks tokio thread for minutes with sync `Command::new`. Fix: `tokio::process::Command`.

**High:**
- `config_options` from `chat.attach` fetched but dropped in `attachSession`. Model selector empty until `configOptionUpdate` arrives. Fix: parse and store in `attachSession`.
- **Agent availability mismatch**: UI shows registry agents, but `resolve_agent_launch` resolves from `.threadmill.yml`. User said: "remove .threadmill.yml agents entirely — registry is the ONLY path." Fix: rewrite `resolve_agent_launch` to use agent registry catalog. Remove `load_project_agents`, `default_agents`, `Project.agents` field, `parseAgentConfigs`.
- Log spam: ~15 `Logger.chat.info` calls in computed properties and SwiftUI body renders. Fix: remove or downgrade to `.debug`.
- Duplicate `sessionUpdateType` in both AgentSessionManager and ChatSessionViewModel. Fix: extract to `SessionUpdate` extension.

**Medium:**
- `switchAgent()` skips `chat.stop` when `channelID == nil` — leaks remote session after disconnect.
- `AgentInstallMethod.init(from:)` defaults unknown types to `.npm` silently — should throw.
- `ChatSessionViewModelCache` doesn't check `sessionID` for invalidation.
- No error surfacing in `AgentsSettingsView` on install failure.
- Full `syncFromDaemon` after install is heavyweight — only registry changed.

## Next Steps

1. **Fix 3 UI bugs** — streaming message IDs per turn, dictionary cache for viewmodels
2. **Unify agent resolution** — remove `.threadmill.yml` agent path entirely, `resolve_agent_launch` uses registry
3. **Fix critical tokio blocking** — `spawn_blocking` for discovery, `tokio::process::Command` for install
4. **Fix config_options dropped** — apply in `attachSession`
5. **Clean up** — log spam, duplicate helper, switchAgent leak, error surfacing, cache invalidation
6. **Assess tests** — per project guidelines (no tautological tests, no source-reading tests)

## Integration Notes

- Spindle changes are on beast at `/home/wsl/dev/spindle` (separate git repo, commit f75a41b).
- The `.threadmill.yml` agent section is slated for removal — only presets should remain in project config.
- `Project.agents` field in GRDB schema will need a migration or graceful deprecation when removed from protocol.
- The `agent.start`/`agent.stop` RPCs in Spindle protocol are now dead code on the Swift side but still exist in Spindle — can be removed once the old path is fully pruned.
