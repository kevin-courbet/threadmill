---
updated: 2026-04-05
---

# Fallback Plan: Spindle-Native Claude Agent SDK Adapter

If Anthropic restricts third-party ACP adapters (like `@agentclientprotocol/claude-agent-acp`),
Spindle will need to speak Claude Code's native protocol directly.

## Current State

- Spindle's ChatService speaks **ACP** (Agent Client Protocol) — JSON-RPC on stdin/stdout
- `claude-agent-acp` (by Zed/agentclientprotocol) bridges ACP ↔ Claude Agent SDK
- If this bridge is banned or broken, we need a Rust-native path in Spindle

## Claude Code's Native Protocol

Claude Code's programmatic interface: `claude -p --bare --input-format stream-json --output-format stream-json`

### Input (stdin → claude)

Newline-delimited JSON. Each line is an `SDKUserMessage`:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Hello"}]}}
```

With `--replay-user-messages`, Claude echoes back each user message on stdout for
acknowledgment, which enables prompt queueing.

### Output (claude → stdout)

Newline-delimited JSON events. Key types:

| `type` | `subtype` | When | Payload |
|--------|-----------|------|---------|
| `system` | `init` | First message | `session_id`, `model`, `tools[]`, `mcp_servers[]`, `permissionMode` |
| `stream_event` | — | During generation | Wraps `BetaRawMessageStreamEvent` (content_block_start/delta/stop, message_start/delta/stop) |
| `assistant` | — | After each turn | Full `BetaMessage` with `content[]`, `usage`, `model`, `stop_reason` |
| `user` | — | Tool result turns | Synthetic user messages with tool results |
| `result` | `success` | End of prompt | `result` text, `session_id`, `total_cost_usd`, `usage`, `modelUsage` |
| `result` | `error_*` | On failure | `errors[]`, same metadata |
| `system` | `compact_boundary` | After compaction | `compact_metadata.trigger`, `pre_tokens` |
| `system` | `status` | Status changes | `status: "compacting"` etc |

### Session Lifecycle

- **New session**: just start the process; `init` system message contains `session_id`
- **Resume**: pass `--resume <sessionId>` or `--continue`
- **Interrupt**: send SIGINT to the process (it handles graceful shutdown)

### Auth

With `--bare`, auth must come from `ANTHROPIC_API_KEY` env var (no OAuth/keychain).
Without `--bare`, it uses the standard claude login flow.

## Translation Mapping: Claude SDK → ACP

### Handshake

ACP expects `initialize` → response, then `session/new` → response.
For the native adapter, Spindle would:

1. Spawn `claude -p --bare --input-format stream-json --output-format stream-json --include-partial-messages --replay-user-messages`
2. Read the `system/init` message from stdout
3. Synthesize the ACP `initialize` response from the init data
4. Synthesize the ACP `session/new` response:
   - `sessionId` ← `init.session_id`
   - `models` ← `init.model` + info from `query.supportedModels()` (not available in raw CLI)
   - `modes` ← hardcode available permission modes

### Streaming

| Claude SDK Event | ACP Equivalent |
|------------------|----------------|
| `stream_event` with `content_block_start` (type=text) | `session/update` → `agent_message_chunk` (text) |
| `stream_event` with `text_delta` | `session/update` → `agent_message_chunk` (text append) |
| `stream_event` with `content_block_start` (type=thinking) | `session/update` → `agent_message_chunk` (thinking) |
| `stream_event` with `thinking_delta` | `session/update` → `agent_message_chunk` (thinking append) |
| `stream_event` with `content_block_start` (type=tool_use) | `session/update` → `tool_call` |
| `assistant` message with tool_use blocks | `session/update` → `tool_call` (if not already streamed) |
| `user` message with tool_result | `session/update` → `tool_update` |
| `result` with `success` | End of prompt, return `stopReason` |
| `result` with `error_*` | Error response |

### Tool Permissions

The big gap. ACP has `requestPermission` which Spindle proxies to the Mac app.
Claude's raw CLI uses `--allowedTools` and `--permissionMode` but has no
interactive permission flow over stream-json.

Options:
1. **`--dangerously-skip-permissions`** — skip all checks (not ideal)
2. **`--permission-mode acceptEdits`** — auto-accept edits, deny shell commands not in allowedTools
3. **Custom `canUseTool`** — only available via the Agent SDK (TypeScript/Python), not raw CLI
4. **`--permission-prompt-tool`** — pipe permission requests through an MCP tool (complex but possible)

Option 4 is the most faithful: Spindle runs a minimal MCP server that the Claude
process connects to. Permission requests come in as MCP tool calls, Spindle
translates them to ACP `requestPermission`, gets the user's decision from the Mac
app, and returns the result. This preserves the interactive permission UX.

### What's Lost

- **Config options at runtime**: Claude SDK exposes `setModel()`, `setPermissionMode()` etc.
  Raw CLI can only set these at launch via flags.
- **Session listing/forking**: SDK has `listSessions()`, `forkSession()`. Not available via CLI.
- **Slash commands**: SDK's `supportedCommands()`. Not exposed in stream-json output.
- **Prompt queueing**: With `--replay-user-messages` we get acknowledgments, but the
  SDK's `Pushable<SDKUserMessage>` stream is more robust.

## Implementation Sketch

```rust
// In ChatService, add a protocol variant
enum AgentProtocol {
    Acp,             // existing: opencode, codex, gemini, etc.
    ClaudeSdkStream, // new: raw claude -p stream-json
}

// In agent_registry.rs, add protocol field to BuiltInAgent
struct BuiltInAgent {
    // ... existing fields ...
    protocol: AgentProtocol,
}

// In run_chat_session(), dispatch based on protocol
match protocol {
    AgentProtocol::Acp => {
        // existing perform_handshake() + binary frame relay
    }
    AgentProtocol::ClaudeSdkStream => {
        // spawn claude with stream-json flags
        // read init message, synthesize ACP handshake responses
        // loop: read stream events, translate to ACP frames, relay to WebSocket
        // on user prompt from Mac: write SDKUserMessage to stdin
    }
}
```

## Reference

- Claude Agent SDK TypeScript docs: https://platform.claude.com/docs/en/agent-sdk/typescript
- Claude CLI reference: https://code.claude.com/docs/en/cli-reference
- Claude headless/programmatic mode: https://code.claude.com/docs/en/headless
- ACP spec: https://agentclientprotocol.com
- Current bridge source: https://github.com/agentclientprotocol/claude-agent-acp
