---
updated: 2026-03-17
---

# Communication Protocol

## Overview

Threadmill (macOS app) and Spindle (daemon on beast/WSL2) use one WebSocket connection.

- Text frames: JSON-RPC 2.0 requests, responses, and server notifications.
- Binary frames: terminal input/output multiplexed by `channel_id`.

```
Threadmill (macOS)                      Spindle (beast/WSL2)
+--------------------+  SSH -L tunnel  +----------------------+
| Swift app          |<--------------->| Rust daemon          |
| URLSession WS      |   ws://127.0.0.1:19990                 |
| Relay + Ghostty    |                 | tokio-tungstenite WS |
+--------------------+                 +----------------------+
```

## Connection Flow

1. Threadmill starts SSH tunnel (unless `THREADMILL_DISABLE_SSH_TUNNEL`): local `<daemonPort>` -> remote `<daemonPort>`.
2. Threadmill opens WebSocket (`ws://127.0.0.1:<daemonPort>` when tunneled, otherwise `ws://<host>:<daemonPort>`).
3. Threadmill sends `session.hello`; daemon returns negotiated `session_id` + capabilities.
4. `onConnected` runs `TerminalMultiplexer.reattachAll()`.
5. `SyncService.syncFromDaemon()` fetches `state.snapshot` and refreshes local cache/UI.
6. Client keeps a 30s ping loop while connected.

## Activity Diagrams

### Connection establishment (tunnel -> ws -> session.hello -> sync)

```text
Threadmill              SSH Tunnel                  Spindle
    |                       |                          |
    | start tunnel          |------------------------->|
    | ws connect            |=========================>|
    | session.hello         |------------------------->|
    |<----------------------|      {session_id,...}    |
    | state=connected       |                          |
    | reattachAll()         |=========================>|
    | state.snapshot        |------------------------->|
    |<----------------------|                 [Project]|
    |                         |                         >|
    |<----------------------|                  [Thread]|
```

### Thread creation (thread.create -> progress -> status_changed -> terminal.attach)

```text
User/App                   Threadmill                     Spindle
   |                          |                             |
   | create thread            | thread.create ------------>|
   |                          |<------------ Thread(creating)
   |                          |<------------ thread.created
   |                          |<------------ thread.progress(...)
   |                          |<------------ thread.status_changed creating->active
   | select preset            | preset.start ------------->|
   |                          | terminal.attach ---------->|
   |                          |<------------ {channel_id}
```

### Terminal I/O (attach -> binary frames -> relay -> ghostty)

```text
Ghostty <-> threadmill-relay <-> RelayEndpoint <-> WebSocket <-> Spindle <-> tmux pane

Output path:
tmux pipe-pane -O -> [u16 channel_id][bytes] -> RelayEndpoint -> unix socket -> relay -> Ghostty

Input path:
Ghostty keystrokes -> relay -> unix socket -> RelayEndpoint
-> [u16 channel_id][bytes] -> Spindle -> pipe-pane -I -> tmux pane
```

### Project clone (project.clone -> clone_progress -> project appears)

```text
User/App                     Threadmill                       Spindle
   |                            |                                |
   | project.clone {url,path?}  |------------------------------->|
   |                            |<------------- project.clone_progress(fetching)
   |                            |<------------- project.clone_progress(ready)
   |                            |<---------------------- Project
   |                            |<------------- project.added
   |                            |<------------- state.delta(project.added)
   |                            | sync (project.list/thread.list)
```

### Preset lifecycle (preset.start -> process_event on crash -> preset.restart)

```text
Threadmill                         Spindle/tmux
   |                                   |
   | preset.start -------------------->|
   |<------------------------ {ok:true}|
   |<---------------- preset.process_event(started)
   | ... monitor loop ...              |
   |<---------------- preset.process_event(exited|crashed)
   | preset.restart ------------------>|
   |<------------------------ {ok:true}|
```

### Reconnect flow (disconnect -> reconnect -> re-sync -> re-attach terminals)

```text
Transport drops
  -> ConnectionManager.handleTransportDrop()
  -> state=disconnected, stop ping, close ws+tunnel
  -> exponential backoff reconnect (max 8)
  -> reconnect tunnel + websocket
  -> ping -> connected
  -> onConnected: reattachAll()
  -> onConnected: syncFromDaemon()
```

## RPC Envelope

Request:
```json
{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
```

Success response:
```json
{"jsonrpc":"2.0","id":1,"result":"pong"}
```

Error response:
```json
{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"..."}}
```

Server notification (event):
```json
{"jsonrpc":"2.0","method":"thread.status_changed","params":{"thread_id":"...","old":"creating","new":"active"}}
```

## RPC Types

`PresetConfig`
```json
{"name":"editor","command":"nvim","cwd":"relative/subdir"}
```

`Project`
```json
{"id":"<uuid>","name":"repo","path":"/home/wsl/dev/repo","default_branch":"main","presets":[PresetConfig]}
```

`ProjectLookupResult`
```json
{"exists":true,"is_git_repo":true,"project_id":"<uuid>|null"}
```

`Thread`
```json
{"id":"<uuid>","project_id":"<uuid>","name":"feat-x","branch":"feat-x","worktree_path":"/home/wsl/dev/.threadmill/repo/feat-x","status":"creating|active|closing|closed|hidden|failed","source_type":"new_feature|existing_branch|pull_request|main_checkout","created_at":"RFC3339","tmux_session":"tm_xxx","port_offset":20}
```

`ThreadProgress`
```json
{"thread_id":"<uuid>","step":"fetching|creating_worktree|copying_files|running_hooks|starting_presets|ready","message":"...","error":"..."}
```

`PresetProcessEvent`
```json
{"thread_id":"<uuid>","preset":"terminal","event":"started|exited|crashed","exit_code":1,"crash_context":{"signal":"SIGSEGV","reason":"segfault","last_output":["...","..."]}}
```

`PresetOutputEvent`
```json
{"thread_id":"<uuid>","preset":"dev-server","stream":"stdout|stderr","chunk":"line of output"}
```

`FileBrowserEntry`
```json
{"name":"foo.rs","path":"/full/path/foo.rs","isDirectory":false,"size":1234}
```

`FileReadPayload`
```json
{"content":"file contents as string","size":1234}
```

`FileGitStatusResult`
```json
{"entries":{"src/main.rs":"modified","new_file.txt":"untracked"}}
```

## RPC Methods (exactly dispatched in `rpc_router.rs`)

`session.hello`
- Params: `{"client":{"name":"threadmill-macos","version":"<string>"},"protocol_version":"2026-03-17","capabilities":["..."],"required_capabilities":["..."]}`
- Result: `{"session_id":"<string>","protocol_version":"2026-03-17","capabilities":["..."],"required_capabilities":["..."],"state_version":<u64>}`
- `capabilities` advertises everything the sender supports; `required_capabilities` is the subset it requires from the peer for the session to proceed.
- Legacy clients may omit request `required_capabilities`; Spindle then treats the request `capabilities` list as the required set.

`ping`
- Params: omitted, `null`, or `{}`
- Result: `"pong"`

`system.stats`
- Params: omitted, `null`, or `{}`
- Result: `{"load_avg_1m":<f64>,"memory_total_mb":<u32>,"memory_used_mb":<u32>,"opencode_instances":<u32>}`

`state.snapshot`
- Params: omitted, `null`, or `{}`
- Result: `{"state_version":<u64>,"projects":[Project],"threads":[Thread]}`

`project.list`
- Params: omitted, `null`, or `{}`
- Result: `[Project]`

`project.lookup`
- Params: `{"path":"<absolute path on beast>"}`
- Result: `{"exists":<bool>,"is_git_repo":<bool>,"project_id":"<uuid>|null"}`
- Used before `project.add` / `project.clone` to determine whether the path exists, is already a git repo, and is already registered with Spindle

`project.add`
- Params: `{"path":"<absolute path on beast>"}`
- Result: `Project`

`project.clone`
- Params: `{"url":"<git url>","path":"<optional absolute path>"}`
- Result: `Project`

`project.remove`
- Params: `{"project_id":"<uuid>"}`
- Result: `{"removed":true|false}`

`project.branches`
- Params: `{"project_id":"<uuid>"}`
- Result: `["main","feature/x",...]`

`project.browse`
- Params: `{"path":"<absolute path on beast>"}`
- Result: `[{"name":"...","is_dir":true,"is_git_repo":true}, ...]` (`is_git_repo` only for directories)

`thread.create`
- Params: `{"project_id":"<uuid>","name":"<thread name>","source_type":"new_feature|existing_branch|pull_request|main_checkout","branch":"<optional branch>"}`
- Result: `Thread` (returned before async workflow completes)

`thread.cancel`
- Params: `{"thread_id":"<uuid>"}`
- Result: `{"status":"failed"}`
- Cancels an in-flight `thread.create` workflow and marks the thread failed so clients can remove it from default active-thread views

`thread.list`
- Params: omitted, `null`, `{}`, or `{"project_id":"<uuid>"}`
- Result: `[Thread]`

`thread.close`
- Params: `{"thread_id":"<uuid>","mode":"close|hide"}`
- Result: `{"status":"creating|active|closing|closed|hidden|failed"}`

`thread.hide`
- Params: `{"thread_id":"<uuid>"}`
- Result: `{"status":"hidden"}`

`thread.reopen`
- Params: `{"thread_id":"<uuid>"}`
- Result: `Thread`

`terminal.attach`
- Params: `{"thread_id":"<uuid>","preset":"<name>"}`
- Result: `{"channel_id":<u16 1..65535>}`

`terminal.detach`
- Params: `{"thread_id":"<uuid>","preset":"<name>"}`
- Result: `{"detached":true|false}`

`terminal.resize`
- Params: `{"thread_id":"<uuid>","preset":"<name>","cols":<u32>,"rows":<u32>}`
- Result: `{"resized":true}`

`preset.start`
- Params: `{"thread_id":"<uuid>","preset":"<name>"}`
- Result: `{"ok":true}`

`preset.stop`
- Params: `{"thread_id":"<uuid>","preset":"<name>"}`
- Result: `{"ok":true|false}`

`preset.restart`
- Params: `{"thread_id":"<uuid>","preset":"<name>"}`
- Result: `{"ok":true}`

`file.list`
- Params: `{"path":"<absolute path>"}`
- Result: `{"entries":[FileBrowserEntry]}`
- Path must be within a known project/worktree root
- Sorted: directories first, then alphabetical case-insensitive
- TOCTOU-hardened with O_NOFOLLOW + fd validation

`file.read`
- Params: `{"path":"<absolute path>"}`
- Result: `{"content":"<utf-8 string>","size":<u64>}`
- Max 5MB, UTF-8 only (binary files return error)
- Path authorization same as file.list

`file.git_status`
- Params: `{"path":"<absolute worktree path>"}`
- Result: `{"entries":{"relative/path":"modified|added|deleted|renamed|untracked|conflicted"}}`
- Runs `git status --porcelain=v1 -uall` in the worktree

## Events (Spindle -> Threadmill)

`thread.progress`
- Params: `ThreadProgress`

`project.clone_progress`
- Params: `ThreadProgress` (`thread_id` carries clone operation UUID)

`thread.status_changed`
- Params: `{"thread_id":"<uuid>","old":"<ThreadStatus>","new":"<ThreadStatus>"}`

`thread.created`
- Params: `{"thread":Thread}`

`thread.removed`
- Params: `{"thread_id":"<uuid>"}`
- Status: defined/reserved, not currently emitted by daemon

`project.added`
- Params: `{"project":Project}`

`project.removed`
- Params: `{"project_id":"<uuid>"}`

`preset.process_event`
- Params: `PresetProcessEvent`

`preset.output`
- Params: `PresetOutputEvent`

`state.delta`
- Params:
```json
{
  "state_version": 42,
  "operations": [
    {"op_id":"op-1","type":"project.added","project": Project},
    {"op_id":"op-2","type":"project.removed","project_id":"<uuid>"},
    {"op_id":"op-3","type":"thread.created","thread": Thread},
    {"op_id":"op-4","type":"thread.removed","thread_id":"<uuid>"},
    {"op_id":"op-5","type":"thread.status_changed","thread_id":"<uuid>","old":"creating","new":"active"},
    {"op_id":"op-6","type":"preset.process_event","thread_id":"<uuid>","preset":"terminal","event":"started|exited|crashed","exit_code":1},
    {"op_id":"op-7","type":"preset.output","thread_id":"<uuid>","preset":"dev-server","stream":"stderr","chunk":"stack trace"}
  ]
}
```

## Binary Frame Format

- Bytes: `[channel_id_be_u16][payload_bytes...]`
- Client -> daemon: relay input payload for attached tmux pane via pipe-pane -I.
- Daemon -> client: tmux pane output payload via pipe-pane -O.
- Channel IDs are ephemeral per WebSocket connection and must be reacquired after reconnect via `terminal.attach`.
- Pre-registration buffering: binary frames arriving before `terminal.attach` response are buffered by `TerminalMultiplexer` and flushed when the endpoint is registered.
- Scrollback replay: on attach, Spindle sends `tmux capture-pane` output with CRLF line endings (bare LF converted to CRLF for correct terminal rendering).

## Error Codes and Behavior

- Daemon returns structured JSON-RPC errors with `code`, `message`, and optional `data`.
- Error payload shape: `{"code":-32041,"message":"...","data":{"kind":"terminal.session_missing","retryable":false,"details":{...}}}`.
- Common codes:
  - `-32601` method not found (`rpc.method_not_found`)
  - `-32602` invalid params (`rpc.invalid_params`)
  - `-32000` session not initialized (`session.not_initialized`)
  - `-32004` domain object not found (`thread.not_found`, etc)
  - `-32041` terminal attach session missing (`terminal.session_missing`)
- Invalid JSON or wrong `jsonrpc` returns an error response with `id: null` if request id is unavailable.
- For notifications (no `id`), daemon does not send error responses; failures are only logged server-side.

## Port Management

- `.threadmill.yml` controls per-thread ports via `ports.base` (default `3000`) and `ports.offset` (default `20`, must be > 0).
- On `thread.create`, Spindle allocates the smallest unused `port_offset` for that project among threads not in `closed|failed`.
- Every `Thread` response includes `port_offset`.
- Spindle computes `THREADMILL_PORT_BASE = ports.base + port_offset` and exports both values in thread env.

## `threadmill-cli` and Shared Protocol

- `threadmill-cli` (`spindle/src/bin/threadmill-cli.rs`) connects to the same WebSocket JSON-RPC server.
- Default URL: `ws://127.0.0.1:19990`; override with `THREADMILL_CLI_WS_URL`.
- It uses standard JSON-RPC requests/responses (same method names and payload shapes).
- Current commands call: `ping`, `project.list`, `thread.list`, `thread.create`, `thread.close`.
- CLI may add `auth_token` in request body (from `~/.config/threadmill/auth_token`); current daemon ignores that field.

## Event Handling on Threadmill Side

`AppState.handleDaemonEvent` currently handles these methods explicitly:

- `thread.status_changed`: update local thread status, attach/detach behavior by status.
- `thread.progress`: log and mark failed when progress indicates failure.
- `project.clone_progress`: log clone progress.
- `state.delta`: apply known operations (`thread.status_changed`, `preset.output`) and sync for broader mutations.
- `preset.process_event`: capture crash context logs and schedule sync.
- `preset.output`: buffer last output lines per thread/preset for crash diagnostics.
- `thread.created`, `thread.removed`, `project.added`, `project.removed`: schedule full sync.

Unknown events are ignored.

## Constraints

- Single WebSocket carries RPC, events, and terminal binary data.
- Spindle is source of truth; local DB is a cache.
- `channel_id` values are connection-scoped and not stable across reconnects.
- tmux sessions/worktrees can outlive client disconnects.
