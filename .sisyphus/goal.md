# Goal

Issue: #14 - Add session_id to terminal/preset RPCs
URL: https://github.com/kevin-courbet/threadmill/issues/14

## Problem

The protocol conflates preset names and session IDs. The Mac app sends client-generated session IDs like `"terminal-2"` through the `preset` field, and Spindle reverse-engineers the base preset name by stripping the `-N` suffix via `resolve_base_preset_name`. This is fragile (strips suffixes from any preset, e.g. `"api-v2"` becomes `"api"`), confuses the protocol contract, and leads to three independent copies of name resolution logic across Swift and Rust.

## Solution

Add an optional `session_id` parameter to `preset.start`, `preset.stop`, `terminal.attach`, `terminal.detach`, and `terminal.resize`. Spindle uses `preset` for config lookup and `session_id` for tmux window naming and target key differentiation. Remove `resolve_base_preset_name` entirely.

## Requirements

- [ ] `preset.start` accepts `{ thread_id, preset, session_id? }` — uses `preset` for config, `session_id` (defaulting to `preset`) for tmux window name
- [ ] `terminal.attach` accepts `{ thread_id, preset, session_id? }` — target key is `{thread_id}:{session_id}`, not `{thread_id}:{preset}`
- [ ] `terminal.detach`, `terminal.resize`, `preset.stop` accept `session_id?` and use it for target/window lookup
- [ ] `resolve_base_preset_name` is removed from `preset.rs`
- [ ] Mac sends both `preset` (base name from `AttachmentKey.presetName`) and `session_id` (the session ID) in all RPCs
- [ ] `daemonPreset` parameter removed from `performAttachPreset` — derive locally for validation only
- [ ] Consolidate the two Swift copies of preset name resolution (`AttachmentKey.presetName` and `TerminalModeActions.presetName(forSessionID:)`) into a single static method
- [ ] `protocol/threadmill-rpc.schema.json` updated with new param
- [ ] Backward compatible: omitting `session_id` defaults to `preset` value (single-instance presets work unchanged)

## Technical Approach

### Architecture

```
Mac                                     Spindle
────                                    ───────
preset.start({                          1. Look up config by `preset` ("terminal")
  preset: "terminal",                   2. Create tmux window named `session_id` ("terminal-2")
  session_id: "terminal-2"              3. target_key = "{thread_id}:terminal-2"
})

terminal.attach({                       1. Find window by `session_id` name
  preset: "terminal",                   2. Unique channel per session_id
  session_id: "terminal-2"              3. Scrollback replay sent
})
```

- `preset` = config identity (what command to run, what cwd)
- `session_id` = instance identity (which tmux window, which channel)
- Named presets (`dev-server`) send no `session_id` — defaults to preset name, single-instance as before

### Protocol Changes

All five RPCs gain optional `session_id: string`:
- `preset.start`, `preset.stop`: window name = `session_id ?? preset`
- `terminal.attach`, `terminal.detach`, `terminal.resize`: target key uses `session_id ?? preset`

## Implementation Phases

### Phase 1: Spindle protocol + params
- Add `session_id: Option<String>` to `PresetStartParams`, `PresetStopParams`, `TerminalAttachParams`, `TerminalDetachParams`, `TerminalResizeParams` in `protocol.rs`
- In each service function, compute `effective_id = params.session_id.unwrap_or(params.preset.clone())`
- `preset.start`: look up config by `params.preset`, create window named `effective_id`
- `terminal.attach`: target key = `{thread_id}:{effective_id}`, window lookup by `effective_id`
- Remove `resolve_base_preset_name` from `preset.rs`
- Update `threadmill-rpc.schema.json`
- **Verify:** `cargo test` — all existing tests pass (they omit `session_id`, so default kicks in)

### Phase 2: Mac sends session_id
- Consolidate `AttachmentKey.presetName` and `TerminalModeActions.presetName(forSessionID:)` into `Preset.baseName(forSessionID:)`
- `performAttachPreset`: send `preset: baseName, session_id: sessionID` in `preset.start` and `terminal.attach`
- `stopPreset`: send `preset: baseName, session_id: sessionID` in `preset.stop`
- Remove `daemonPreset` parameter from `performAttachPreset`
- **Verify:** `swift test` passes, manual test: create Terminal 2 tab, verify separate shell

## Edge Cases & Error Handling

- `session_id` containing special characters (slashes, spaces): Spindle should validate it's a safe tmux window name
- `preset.stop` with `session_id` that doesn't match any window: return `{ ok: false }` (existing behavior)

## Out of Scope

- Terminal lifecycle changes (ephemeral vs long-lived) — separate issue
- Cmd+T flow fix — separate issue
- `restartCurrentPreset` fix — separate issue
