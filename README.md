# Threadmill

Native macOS visor for managing development threads (worktrees + tmux sessions) on a remote machine. Pairs with [Spindle](../spindle) as the backend daemon.

## Build

```bash
swift build
```

## Protocol

See `protocol/threadmill-rpc.schema.json` for the JSON-RPC 2.0 contract shared with Spindle.

## Architecture

See `docs/architecture.md` for the full design.
