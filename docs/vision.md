# Threadmill Vision

## Problem

Superset (Electron app) manages git worktrees but has chronic issues:
- Auto-updates wipe LSEnvironment, bypassing the git wrapper
- SHELL/PATH discovery fails with nushell, falling back to bare PATH
- NFS-based worktree checkouts are slow and fragile
- No awareness of AI agent sessions running in worktrees
- Opaque Electron internals make fixes fragile and recurring

## Core Idea

macOS is just a visor. Everything runs on beast (WSL2). A native macOS app (Threadmill) talks to a Rust daemon (Spindle) on beast over a single WebSocket connection. No NFS dependency for any operation.

## Key Features

### 1. Projects
- "Add repository" — either "Open project" (existing repo on beast) or "Clone repo" (from URL)
- Projects define terminal presets, setup hooks, and teardown hooks
- Config lives in `.threadmill.yml` committed to each project repo

### 2. Threads
- A thread = a project + git worktree + branch + tmux session
- Threads are the primary workspace unit, visible in the sidebar grouped by project
- Create a new thread by selecting a project, then choosing:
  - New feature (enter branch name)
  - Existing branch (select from remote branches)
  - From PR URL (extracts branch)
- Closing a thread deletes the worktree (with "hide" option to keep files on disk)
- Thread lifecycle: creating → active → closing → closed | hidden | failed

### 3. Terminal Presets
- A project defines what "dev server" means — could be one command, or multiple parallel commands
- Presets are tabs in the thread view (e.g. [Dev Server] [OpenCode] [Terminal])
- Each preset maps to a tmux window (parallel commands = split panes within that window)
- Preset output is always accessible for introspection (server logs, agent output, etc.)
- Example presets:
  ```yaml
  dev-server:
    commands: [task dev:worktree]
    autostart: true
  dev-full:
    commands: [task dev:worktree, bun run storybook]
    parallel: true
  opencode:
    commands: [opencode]
  terminal:
    commands: [$SHELL]
    autostart: true
  ```

### 4. Setup Hooks
- Global hooks (run for all projects) and per-project hooks
- Some projects need to copy files from main branch to new worktrees (e.g. `.env.local`)
- Setup runs after worktree creation, before presets start
- Teardown runs before worktree deletion
- Example:
  ```yaml
  setup:
    - bun install
    - task db:branch:sync
  teardown:
    - task db:branch:delete
  copy_from_main:
    - .env.local
    - .env.development.local
  ```

### 5. AI Agent Awareness
- OpenCode/Claude Code sessions are just terminal presets — agent-agnostic
- Agents running on beast can discover thread context via `$THREADMILL_THREAD` env var
- Agents can create threads, list threads, attach to sessions via `threadmill-cli` or tmux
- Multiple agents can work in parallel across different worktrees
- Starting work from an agent should create a visible thread in the app

### 6. Persistence via tmux
- All sessions survive: app quit, SSH drops, daemon restarts, network blips
- Reattach from anywhere (phone via SSH, another Mac, an agent)
- No custom PTY management — tmux is the persistence layer

## Non-Goals
- Git diff/commit UI — use VS Code Remote SSH, GitHub Desktop, or neovim in a terminal preset
- Multi-host support — hardcoded for beast
- Generic SSH abstraction — uses beast SSH config directly

## Architecture Split
- **Threadmill** (macOS, Swift/SwiftUI) — the visor, UI, connection management
- **Spindle** (beast, Rust) — the daemon, git/tmux/process orchestration
- **Protocol** — JSON-RPC 2.0 schema owned by Threadmill, consumed by Spindle via git submodule
