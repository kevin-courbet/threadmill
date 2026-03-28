import Foundation

struct MockRPCCall {
    let method: String
    let params: [String: Any]
}

@MainActor
final class MockSpindleServer {
    let fixture: [String: Any]

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdinPipe: Pipe?
    private var bufferedStdout = ""

    private(set) var port: Int?
    private(set) var rpcCalls: [MockRPCCall] = []
    private(set) var receivedPrompts: [String] = []

    init() {
        fixture = MockSpindleServer.chatFixture()
    }

    init(fixture: [String: Any]) {
        self.fixture = fixture
    }

    deinit {
        process?.terminate()
    }

    func start(timeout: TimeInterval = 5) async throws {
        guard process == nil else {
            return
        }

        let data = try JSONSerialization.data(withJSONObject: fixture)
        let fixtureBase64 = data.base64EncodedString()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.pythonServerScript, fixtureBase64]

        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        process.standardInput = stdin

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let chunk = handle.availableData
                guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                self.consumeOutput(text)
            }
        }

        try process.run()
        self.process = process
        stdoutPipe = stdout
        stdinPipe = stdin

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if port != nil {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        throw MockServerError("Timed out waiting for mock spindle to start")
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        stdinPipe = nil
        port = nil
        rpcCalls.removeAll()
        receivedPrompts.removeAll()
        bufferedStdout = ""
    }

    func waitForRPC(method: String, timeout: TimeInterval) async -> MockRPCCall? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let call = rpcCalls.last(where: { $0.method == method }) {
                return call
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func waitForPrompt(containing text: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if receivedPrompts.contains(where: { $0.contains(text) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return receivedPrompts.contains(where: { $0.contains(text) })
    }

    private func consumeOutput(_ text: String) {
        bufferedStdout.append(text)

        while let newline = bufferedStdout.firstIndex(of: "\n") {
            let line = String(bufferedStdout[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            bufferedStdout.removeSubrange(...newline)

            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else {
                continue
            }

            switch type {
            case "ready":
                port = json["port"] as? Int
            case "rpc":
                let method = json["method"] as? String ?? ""
                let params = json["params"] as? [String: Any] ?? [:]
                rpcCalls.append(MockRPCCall(method: method, params: params))
            case "prompt":
                if let text = json["text"] as? String {
                    receivedPrompts.append(text)
                }
            default:
                break
            }
        }
    }

    static func chatFixture() -> [String: Any] {
        let threadID = "thread-chat-fixture"
        let sessionID = "mock-session-1"
        let now = ISO8601DateFormatter().string(from: Date())

        let project: [String: Any] = [
            "id": "project-chat-fixture",
            "name": "Threadmill",
            "path": "/tmp/threadmill",
            "default_branch": "main",
            "presets": [["name": "terminal", "command": "zsh"]],
            "agents": [["name": "opencode", "command": "opencode"]],
        ]

        let thread: [String: Any] = [
            "id": threadID,
            "project_id": "project-chat-fixture",
            "name": "chat-fixture",
            "branch": "feature/chat-fixture",
            "worktree_path": "/tmp/threadmill/chat-fixture",
            "status": "active",
            "source_type": "main_checkout",
            "created_at": now,
            "tmux_session": "",
            "port_offset": 0,
        ]

        let preseededSession: [String: Any] = [
            "session_id": sessionID,
            "thread_id": threadID,
            "agent_name": "opencode",
            "agent_type": "opencode",
            "title": "",
            "status": "ready",
            "model_id": "claude-sonnet-4",
            "capabilities": [
                "modes": [
                    "availableModes": [
                        ["id": "default", "title": "Default"],
                        ["id": "plan", "title": "Plan"],
                    ],
                    "currentModeId": "default",
                ],
                "models": [
                    "availableModels": [
                        ["id": "claude-sonnet-4", "title": "Claude Sonnet 4"],
                        ["id": "gpt-5", "title": "GPT-5"],
                    ],
                    "currentModelId": "claude-sonnet-4",
                ],
            ],
            "created_at": now,
            "updated_at": now,
        ]

        let history: [[String: Any]] = [
            [
                "sessionId": sessionID,
                "update": [
                    "sessionUpdate": "user_message_chunk",
                    "content": ["type": "text", "text": "Hi mock"],
                ],
            ],
            [
                "sessionId": sessionID,
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": "Mock response: Hi mock"],
                ],
            ],
        ]

        return [
            "projects": [project],
            "threads": [thread],
            "chat_sessions": [preseededSession],
            "history": [sessionID: history],
        ]
    }

    private static let pythonServerScript = #"""
import asyncio, base64, json, sys
import websockets

fixture = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))

projects = fixture.get("projects", [])
threads = fixture.get("threads", [])
chat_sessions = {
    session.get("session_id"): dict(session)
    for session in fixture.get("chat_sessions", [])
    if session.get("session_id")
}
history = {
    key: list(value)
    for key, value in fixture.get("history", {}).items()
}
channel_to_session = {}
next_channel = 600

def caps():
    return {
        "modes": {
            "availableModes": [
                {"id": "default", "title": "Default"},
                {"id": "plan", "title": "Plan"}
            ],
            "currentModeId": "default"
        },
        "models": {
            "availableModels": [
                {"id": "claude-sonnet-4", "title": "Claude Sonnet 4"},
                {"id": "gpt-5", "title": "GPT-5"}
            ],
            "currentModelId": "claude-sonnet-4"
        }
    }

def log(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()

def snapshot_threads():
    by_thread = {}
    for s in chat_sessions.values():
        tid = s.get("thread_id")
        if not tid:
            continue
        by_thread.setdefault(tid, []).append(dict(s))
    rows = []
    for t in threads:
        row = dict(t)
        row["chat_sessions"] = by_thread.get(t.get("id"), [])
        rows.append(row)
    return rows

async def send_event(ws, method, params):
    await ws.send(json.dumps({"jsonrpc": "2.0", "method": method, "params": params}))

async def handle_rpc(ws, req):
    global next_channel

    rid = req.get("id")
    method = req.get("method")
    params = req.get("params") or {}
    log({"type": "rpc", "method": method, "params": params})

    def respond(result=None, error=None):
        payload = {"jsonrpc": "2.0", "id": rid}
        if error is not None:
            payload["error"] = error
        else:
            payload["result"] = result if result is not None else {}
        return ws.send(json.dumps(payload))

    if method == "ping":
        await respond({"ok": True})
        return

    if method == "session.hello":
        await respond({"protocol_version": "2026-03-17", "capabilities": []})
        return

    if method == "project.list":
        await respond(projects)
        return

    if method == "thread.list":
        await respond(threads)
        return

    if method == "state.snapshot":
        await respond({
            "threads": snapshot_threads(),
            "chat_sessions": list(chat_sessions.values())
        })
        return

    if method == "chat.start":
        thread_id = params.get("thread_id")
        agent_name = params.get("agent_name", "opencode")
        session_id = f"session-{len(chat_sessions)+1}"
        session = {
            "session_id": session_id,
            "thread_id": thread_id,
            "agent_name": agent_name,
            "agent_type": agent_name,
            "title": "",
            "status": "starting"
        }
        chat_sessions[session_id] = session
        history.setdefault(session_id, [])

        await respond({"session_id": session_id, "status": "starting"})

        await send_event(ws, "chat.session_created", {
            "thread_id": thread_id,
            "session": dict(session)
        })

        session["status"] = "ready"
        session["capabilities"] = caps()
        await send_event(ws, "chat.session_ready", {
            "thread_id": thread_id,
            "session_id": session_id,
            "capabilities": caps()
        })
        return

    if method == "chat.load":
        session_id = params.get("session_id")
        session = chat_sessions.get(session_id)
        await respond({"session": dict(session) if session else {}})
        return

    if method == "chat.stop":
        session_id = params.get("session_id")
        session = chat_sessions.get(session_id)
        if session:
            session["status"] = "ended"
        await respond({"ok": True})
        return

    if method == "chat.list":
        thread_id = params.get("thread_id")
        sessions = [
            dict(s)
            for s in chat_sessions.values()
            if s.get("thread_id") == thread_id
        ]
        await respond(sessions)
        return

    if method == "chat.attach":
        session_id = params.get("session_id")
        channel = next_channel
        next_channel += 1
        channel_to_session[channel] = session_id
        await respond({"channel_id": channel})
        return

    if method == "chat.detach":
        channel = params.get("channel_id")
        channel_to_session.pop(channel, None)
        await respond({"ok": True})
        return

    if method == "chat.history":
        session_id = params.get("session_id")
        updates = history.get(session_id, [])
        await respond({"updates": updates, "next_cursor": None})
        return

    await respond(error={"code": -32601, "message": f"Method not found: {method}"})

def parse_prompt_text(params):
    blocks = params.get("prompt") or []
    if not blocks:
        return ""
    first = blocks[0]
    if isinstance(first, dict):
        return first.get("text", "")
    return ""

async def handle_binary(ws, frame):
    if len(frame) < 2:
        return

    channel = (frame[0] << 8) | frame[1]
    payload = frame[2:]
    for line in payload.split(b"\n"):
        if not line:
            continue
        try:
            req = json.loads(line.decode("utf-8"))
        except Exception:
            continue

        method = req.get("method")
        if method == "session/prompt":
            params = req.get("params") or {}
            session_id = params.get("sessionId") or channel_to_session.get(channel)
            prompt_text = parse_prompt_text(params)
            log({"type": "prompt", "session_id": session_id, "text": prompt_text})

            response_text = f"Mock response: {prompt_text}" if prompt_text else "Mock response"
            update = {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": response_text}
                }
            }
            history.setdefault(session_id, []).append(update)

            notif = {"jsonrpc": "2.0", "method": "session/update", "params": update}
            response = {
                "jsonrpc": "2.0",
                "id": req.get("id"),
                "result": {"stopReason": "end_turn"}
            }

            out = bytes([channel >> 8, channel & 0xFF])
            out += json.dumps(notif).encode("utf-8") + b"\n"
            out += json.dumps(response).encode("utf-8") + b"\n"
            await ws.send(out)
            continue

        if method == "session/set_mode":
            response = {"jsonrpc": "2.0", "id": req.get("id"), "result": {"success": True}}
            out = bytes([channel >> 8, channel & 0xFF]) + json.dumps(response).encode("utf-8") + b"\n"
            await ws.send(out)
            continue

        if method == "session/set_model":
            response = {"jsonrpc": "2.0", "id": req.get("id"), "result": {"success": True}}
            out = bytes([channel >> 8, channel & 0xFF]) + json.dumps(response).encode("utf-8") + b"\n"
            await ws.send(out)

async def ws_handler(websocket):
    async for message in websocket:
        if isinstance(message, str):
            try:
                req = json.loads(message)
            except Exception:
                continue
            await handle_rpc(websocket, req)
        else:
            await handle_binary(websocket, message)

async def main():
    server = await websockets.serve(ws_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    log({"type": "ready", "port": port})
    await asyncio.Future()

asyncio.run(main())
"""#
}

struct MockServerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
