# Goal

Issue: #2 - PRD: ACP-based Chat with Aizen-quality UI
URL: https://github.com/kevin-courbet/threadmill/issues/2

## Problem

Threadmill's chat mode is wired to opencode serve (HTTP REST + SSE) with a flat `OCMessagePart` rendering pipeline. Tool calls are detected by string-matching on `type` fields, code blocks lack syntax highlighting, there is no model/agent selector, no mode switcher (chat/code/plan), and no timeline grouping. The result is a significantly inferior chat experience compared to what Aizen achieves with the ACP protocol and typed rendering pipeline.

Additionally, provider subscription lock-in (Claude Max, Codex, Gemini Pro) means opencode serve — limited to open API models — can't access premium subscription-gated models. The official agent CLIs (claude-code, codex, gemini) handle their own subscription auth, but Threadmill can't talk to them today.

## Solution

Replace the opencode serve HTTP/SSE chat backend with ACP (Agent Client Protocol) over stdio, relayed through Spindle as a dumb byte pipe. Add a new `agents` config section to `.threadmill.yml` supporting multiple ACP agents (opencode, claude, codex, gemini). Rebuild the entire chat UI using `swift-acp` types and Aizen-quality rendering — timeline grouping, tool call groups, exploration clustering, syntax-highlighted code blocks, agent/mode selectors, animated input bar, and shimmer thinking indicator.

## Requirements

### Must Have

- **ACP byte relay in Spindle**: `agent.start`, `agent.stop`, `agent.send` RPCs. Spindle spawns ACP agent processes as `tokio::process::Child`, relays stdin/stdout as binary frames with channel ID prefix (same `[u16be channel_id][raw bytes]` format as terminals)
- **`.threadmill.yml` agents section**: Parsed by Spindle alongside presets. Schema: `agents: { name: { command: string, cwd?: string } }`. Exposed via `project.list` response
- **`swift-acp` integration**: Add SPM dependency. Replace `OpenCodeClient`/`OCMessagePart`/`OCMessage`/SSE parser with ACP `Client` types (`ToolCall`, `MessageItem`, `ContentBlock`, `SessionUpdateNotification`, `ModeInfo`, `ModelInfo`)
- **Agent session lifecycle on Swift side**: `AgentSessionManager` wrapping `swift-acp` Client — create session, send prompt, receive streaming updates, cancel, resume. One ACP client per agent process, multiplexed through Spindle
- **Timeline model**: `TimelineItem` enum (`.message`, `.toolCall`, `.toolCallGroup`, `.turnSummary`). `ToolCallGroup` with `ExplorationCluster` for consecutive read/search/grep calls. `TurnSummary` with tool count, duration, file chips
- **Agent selector in input bar**: Pick from configured agents per project. Switch agent per chat session. Reflects `agents` from `.threadmill.yml`
- **Mode selector**: Chat/Code/Plan modes via ACP `setMode`/`currentModeUpdate`. Shown when agent advertises modes (opencode does). Keyboard shortcut to cycle
- **Tool call rendering**: Expandable accordion with status dot (running/complete/failed), tool icon, title, syntax-highlighted arguments/results via tree-sitter, diff rendering for edits, nested child tool calls
- **Code block syntax highlighting**: Port tree-sitter highlighting to chat code blocks using existing `CodeEditSourceEditor`/`CodeEditLanguages` packages (already used in file browser)
- **Markdown rendering upgrade**: Streaming background parse (8-16ms incremental), `CombinedTextBlockView` for cross-block text selection via single `NSTextView`, theme-aware inline code coloring
- **Animated gradient input bar**: `CAGradientLayer` conic gradient border during streaming, dashed blue border in plan mode, thin separator when idle. Respects `accessibilityReduceMotion`
- **Shimmer thinking indicator**: Transient shimmer text above input bar during agent thinking (replaces collapsible thinking block). `CAGradientLayer` highlight band masked to text shape
- **Scroll management**: `ScrollBottomObserver` using `NSScrollView` KVO with hysteresis threshold (enter 24.5pt, leave 36pt). `userScrolledUp` intent flag. No GeometryReader polling
- **Virtual timeline window**: Show last 140 items. "Load more (N remaining)" button loads 120 at a time. Preserve scroll anchor when loading older items
- **ChatConversation GRDB migration**: Replace `opencodeSessionID` with `agentSessionID` + `agentType` columns. New migration v6
- **Fridge old implementation**: Move `OpenCodeClient.swift`, `OpenCodeModels.swift`, SSE parser, `ChatRenderSupport.swift` to `Sources/Threadmill/_Fridge/`. Not compiled

### Nice to Have

- Turn file chips: Filename + green +N / red -N line count badges in turn summary, tappable
- Streaming performance: Two-tier coalescing (50ms message flush + 60ms tool call throttle), custom deduplication comparing only tail of content
- Agent config options: Surface ACP `availableConfigOptions` (effort level, extended thinking toggle) as menu in input bar

## Implementation Phases

### Phase 1: Spindle ACP Agent Service
- Add `AgentConfig` to `.threadmill.yml` parser and `project.list` response
- Implement `src/services/agent.rs`: spawn agent process, hold Child handle, monitor lifecycle
- Add `agent.start(project, agent_name) → channel_id` and `agent.stop(channel_id)` RPCs
- Wire binary frame dispatch: route frames to agent stdin/stdout by channel ID
- Add `agent.status_changed` event (started/exited/crashed)

### Phase 2: Swift ACP Transport Layer
- Add `swift-acp` to `Package.swift`
- Implement `AgentSessionManager`: binary frame routing, ACP Client wrapping, session lifecycle
- Add `agent.start`/`agent.stop` RPC calls to `ConnectionManager`/`AppState`
- Parse `AgentConfig` from `project.list` response, store in `Project` model
- GRDB migration v6: `agentType` + `agentSessionID` columns on `ChatConversation`

### Phase 3: Timeline Model & Data Layer
- Implement `TimelineItem` enum, `ToolCallGroup`, `ExplorationCluster`, `TurnSummary` models
- Implement `ChatSessionViewModel` with timeline building algorithm
- Streaming notification handling

### Phase 4: Chat UI Rebuild — Core Views
- `ChatSessionView`, `ChatMessageList`, `MessageBubbleView`, `ChatInputBar`
- `ScrollBottomObserver` with KVO hysteresis
- Fridge old files

### Phase 5: Chat UI — Rich Rendering
- `ToolCallView`, `ToolCallGroupView`, `TurnSummaryView`
- `MarkdownView`, `CodeBlockView`, `InlineDiffView`

### Phase 6: Chat UI — Polish
- Animated gradient border, shimmer, mode/agent selectors
- Streaming performance tuning
