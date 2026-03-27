# Goal

Issue: #21 - Spindle: Chat service core - RPCs, events, state snapshot
URL: https://github.com/kevin-courbet/threadmill/issues/21

## Problem

Spindle has no awareness of chat sessions. It blindly relays ACP binary frames between Mac and agent processes. There are no RPCs to create, list, attach to, or manage chat sessions. The state snapshot does not include chat session information. This means clients cannot discover existing sessions on reconnect, multiple clients cannot coordinate, and chat sessions do not survive client disconnects.

## Solution

Add a new `chat` service to Spindle mirroring the terminal/preset architecture. Spindle manages the full ACP agent lifecycle (spawn, initialize, session/new, session/load) and exposes it through JSON-RPC methods. Chat sessions become first-class state tracked in the snapshot and communicated via events.

## Requirements

- [ ] `chat.start(thread_id, agent_name)` RPC: spawns agent process, begins ACP handshake async, returns `{ session_id, status: "starting" }` immediately
- [ ] `chat.load(thread_id, session_id)` RPC: reconnects to existing session via `agent.start` (if needed) -> `initialize` -> `session/load`, returns `{ session_id, status: "starting" }`
- [ ] `chat.stop(thread_id, session_id)` RPC: stops agent process, marks session archived
- [ ] `chat.list(thread_id)` RPC: returns all sessions for a thread with metadata (session_id, agent_type, status, title, model_id, created_at)
- [ ] `chat.attach(thread_id, session_id)` RPC: allocates binary channel for ACP frame relay, returns `{ channel_id }`. Multiple clients can attach simultaneously.
- [ ] `chat.detach(channel_id)` RPC: releases binary channel, agent keeps running
- [ ] `chat.session_created` event emitted when `chat.start` is accepted (agent spawning)
- [ ] `chat.session_ready` event emitted after ACP handshake completes, includes `{ thread_id, session_id, modes?, models?, config_options? }`
- [ ] `chat.session_failed` event emitted if agent start or ACP handshake fails, includes `{ thread_id, session_id, error }`
- [ ] `chat.session_ended` event emitted when agent exits or session is stopped, includes `{ thread_id, session_id, reason }`
- [ ] State snapshot `threads[].chat_sessions` array with: `session_id, agent_type, status, title, model_id, created_at`
- [ ] State delta support for chat session additions/removals/updates
- [ ] `chat.start` times out the ACP handshake after 30s, emitting `chat.session_failed`
- [ ] Thread close (`thread.close`) stops all chat sessions for that thread
- [ ] Binary frame relay fans out to all attached clients for the same session

## Technical Approach

### Architecture

New `src/services/chat.rs` following the pattern of `src/services/terminal.rs` and `src/services/preset.rs`.

Internal state per chat session:
```rust
struct ChatSession {
    session_id: String,
    thread_id: String,
    agent_type: String,       // "opencode", "claude", etc.
    acp_session_id: String,   // from session/new or session/load response
    status: ChatSessionStatus, // Starting, Ready, Failed, Ended
    model_id: Option<String>,
    title: Option<String>,
    modes: Option<Vec<ModeInfo>>,
    models: Option<Vec<ModelInfo>>,
    created_at: DateTime<Utc>,
    attached_channels: HashSet<u16>, // multiple clients
}
```

### ACP handshake

`chat.start` spawns the agent process (reusing existing `agent.start` infrastructure), then performs the ACP `initialize` + `session/new` handshake in a background task. On success, updates session status to `Ready` and emits `chat.session_ready` with capabilities extracted from the `session/new` response (modes, models, config_options). On failure, emits `chat.session_failed`.

`chat.load` follows the same pattern but uses `session/load` instead of `session/new`, passing the stored ACP session ID.

### Multi-client attach

`chat.attach` adds a channel ID to the session's `attached_channels` set. The binary frame relay path checks this set and fans out outbound frames (agent -> clients) to all attached channels. Inbound frames (client -> agent) from any attached client are forwarded to the agent.

### RPC dispatch

Add new method constants to `protocol.rs` and dispatch entries in `rpc_router.rs`, following the existing patterns for `terminal.*` and `preset.*` methods.

### State snapshot

Extend the thread payload in `state_store.rs` to include `chat_sessions`. State version increments on session create/ready/fail/end. Delta operations follow the existing `state.delta.operations.v1` pattern.

## Edge Cases & Error Handling

- `chat.start` for a thread that doesn't exist: return RPC error
- `chat.attach` for a session that isn't ready: return RPC error with status info
- `chat.attach` for a session in "starting" state: queue the attach, fulfill when ready
- Agent process crashes after `chat.session_ready`: detect via process monitor, emit `chat.session_ended`, notify all attached channels
- `chat.load` for a session ID that the agent doesn't recognize: `session/load` fails, emit `chat.session_failed`
- Spindle restart: sessions in memory are lost, but JSONL files on disk survive (scrollback issue handles replay)

## Out of Scope

- Scrollback persistence (separate issue)
- Agent status tracking / busy/idle/stalled (separate issue)
- Mac-side client changes
