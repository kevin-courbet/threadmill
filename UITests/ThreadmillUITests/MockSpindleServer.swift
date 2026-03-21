import Foundation
import Network

final class MockSpindleServer {
    struct PresetFixture {
        let name: String
        let command: String
        let cwd: String?

        init(name: String, command: String, cwd: String? = nil) {
            self.name = name
            self.command = command
            self.cwd = cwd
        }
    }

    struct RepoFixture {
        let id: String
        let owner: String
        let name: String
        let fullName: String
        let cloneURL: String
        let defaultBranch: String
        let isPrivate: Bool

        init(id: String, owner: String, name: String, fullName: String, cloneURL: String, defaultBranch: String = "main", isPrivate: Bool = true) {
            self.id = id
            self.owner = owner
            self.name = name
            self.fullName = fullName
            self.cloneURL = cloneURL
            self.defaultBranch = defaultBranch
            self.isPrivate = isPrivate
        }
    }

    struct ThreadFixture {
        let id: String
        let name: String
        let branch: String
        let worktreePath: String
        let createdAt: Date
        let tmuxSession: String
        let status: String
        let sourceType: String

        init(id: String, name: String, branch: String, worktreePath: String, createdAt: Date, tmuxSession: String, status: String = "active", sourceType: String = "new_feature") {
            self.id = id
            self.name = name
            self.branch = branch
            self.worktreePath = worktreePath
            self.createdAt = createdAt
            self.tmuxSession = tmuxSession
            self.status = status
            self.sourceType = sourceType
        }
    }

    struct ProjectFixture {
        let id: String
        let name: String
        let path: String
        let defaultBranch: String
        let presets: [PresetFixture]
        let thread: ThreadFixture
        let repo: RepoFixture?

        init(id: String, name: String, path: String, defaultBranch: String = "main", presets: [PresetFixture], thread: ThreadFixture, repo: RepoFixture? = nil) {
            self.id = id
            self.name = name
            self.path = path
            self.defaultBranch = defaultBranch
            self.presets = presets
            self.thread = thread
            self.repo = repo
        }
    }

    struct RPCRequest {
        let method: String
        let params: [String: Any]?
    }

    private struct MockProject {
        let id: String
        let name: String
        let path: String
        let defaultBranch: String
        let presets: [PresetFixture]
    }

    private struct MockThread {
        let id: String
        let projectID: String
        let name: String
        let branch: String
        let worktreePath: String
        let createdAt: Date
        let tmuxSession: String
        let status: String
        let sourceType: String
    }

    private final class ClientConnection {
        let connection: NWConnection
        private let queue: DispatchQueue
        private let onMessage: (NWProtocolWebSocket.Opcode, Data, ClientConnection) -> Void
        private let onClose: (ClientConnection) -> Void

        init(connection: NWConnection, queue: DispatchQueue, onMessage: @escaping (NWProtocolWebSocket.Opcode, Data, ClientConnection) -> Void, onClose: @escaping (ClientConnection) -> Void) {
            self.connection = connection
            self.queue = queue
            self.onMessage = onMessage
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receiveNextMessage()
                case .cancelled, .failed:
                    self.onClose(self)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        func stop() {
            connection.cancel()
        }

        func sendJSON(_ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else {
                return
            }
            send(opcode: .text, payload: Data(text.utf8))
        }

        func sendBinary(_ payload: Data) {
            send(opcode: .binary, payload: payload)
        }

        private func send(opcode: NWProtocolWebSocket.Opcode, payload: Data) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(identifier: "mock-send", metadata: [metadata])
            connection.send(content: payload, contentContext: context, isComplete: true, completion: .idempotent)
        }

        private func receiveNextMessage() {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self else { return }
                if error != nil {
                    self.onClose(self)
                    return
                }

                if let context,
                   let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   let data
                {
                    self.onMessage(metadata.opcode, data, self)
                    if metadata.opcode == .close {
                        self.onClose(self)
                        return
                    }
                }

                self.receiveNextMessage()
            }
        }
    }

    private let queue = DispatchQueue(label: "threadmill.ui.mock-spindle")
    private let formatter: ISO8601DateFormatter

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    private var projects: [MockProject] = []
    private var threads: [MockThread] = []
    private var requestLog: [RPCRequest] = []
    private var attachments: [UInt16: (threadID: String, preset: String)] = [:]
    private var stateVersion = 1
    private var nextChannelID: UInt16 = 10

    private(set) var port: UInt16 = 0

    init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func useFixture(_ fixture: [ProjectFixture]) {
        queue.sync {
            projects = fixture.map {
                MockProject(id: $0.id, name: $0.name, path: $0.path, defaultBranch: $0.defaultBranch, presets: $0.presets)
            }
            threads = fixture.map {
                MockThread(
                    id: $0.thread.id,
                    projectID: $0.id,
                    name: $0.thread.name,
                    branch: $0.thread.branch,
                    worktreePath: $0.thread.worktreePath,
                    createdAt: $0.thread.createdAt,
                    tmuxSession: $0.thread.tmuxSession,
                    status: $0.thread.status,
                    sourceType: $0.thread.sourceType
                )
            }
            requestLog.removeAll()
            attachments.removeAll()
            stateVersion += 1
            nextChannelID = 10
        }
    }

    func start() throws {
        if listener != nil { return }

        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        let semaphore = DispatchSemaphore(value: 0)
        var startupError: Error?
        var signaled = false

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.accept(connection: connection)
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                if !signaled {
                    signaled = true
                    semaphore.signal()
                }
            case .failed(let error):
                startupError = error
                if !signaled {
                    signaled = true
                    semaphore.signal()
                }
            default:
                break
            }
        }

        queue.async {
            self.listener = listener
            listener.start(queue: self.queue)
        }

        semaphore.wait()
        if let startupError {
            stop()
            throw startupError
        }
    }

    func stop() {
        queue.sync {
            let activeClients = Array(clients.values)
            clients.removeAll()
            for client in activeClients {
                client.stop()
            }
            attachments.removeAll()
            requestLog.removeAll()
            listener?.cancel()
            listener = nil
            port = 0
        }
    }

    func requestCount(method: String) -> Int {
        queue.sync {
            requestLog.filter { $0.method == method }.count
        }
    }

    func requestParams(method: String) -> [[String: Any]] {
        queue.sync {
            requestLog.filter { $0.method == method }.map { $0.params ?? [:] }
        }
    }

    private func accept(connection: NWConnection) {
        let client = ClientConnection(
            connection: connection,
            queue: queue,
            onMessage: { [weak self] opcode, payload, client in
                self?.handle(opcode: opcode, payload: payload, from: client)
            },
            onClose: { [weak self] client in
                self?.clients.removeValue(forKey: ObjectIdentifier(client))
            }
        )
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    private func handle(opcode: NWProtocolWebSocket.Opcode, payload: Data, from client: ClientConnection) {
        switch opcode {
        case .text:
            handleJSONFrame(payload, from: client)
        case .binary:
            client.sendBinary(payload)
        case .close:
            clients.removeValue(forKey: ObjectIdentifier(client))
        default:
            break
        }
    }

    private func handleJSONFrame(_ payload: Data, from client: ClientConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let request = object as? [String: Any],
              let id = request["id"],
              let method = request["method"] as? String
        else {
            return
        }

        let params = request["params"] as? [String: Any]
        queue.async {
            self.requestLog.append(RPCRequest(method: method, params: params))
        }
        client.sendJSON(response(for: method, id: id, params: params))
    }

    private func response(for method: String, id: Any, params: [String: Any]?) -> [String: Any] {
        switch method {
        case "ping":
            return ok(id: id, result: "pong")
        case "session.hello":
            return ok(
                id: id,
                result: [
                    "session_id": "ui-test-session",
                    "state_version": stateVersion,
                    "protocol_version": "2026-03-17",
                    "capabilities": [
                        "state.delta.operations.v1",
                        "preset.output.v1",
                        "rpc.errors.structured.v1",
                    ],
                ]
            )
        case "system.stats":
            return ok(
                id: id,
                result: [
                    "cpu_percent": 12,
                    "load_avg_1m": 0.12,
                    "load_avg_5m": 0.08,
                    "load_avg_15m": 0.05,
                    "memory_used_mb": 512,
                    "memory_total_mb": 2048,
                    "disk_used_gb": 10,
                    "disk_total_gb": 100,
                    "uptime_seconds": 1234,
                    "opencode_running": true,
                    "opencode_instances": 1,
                ]
            )
        case "state.snapshot":
            return ok(id: id, result: ["state_version": stateVersion, "projects": projects.map(projectPayload), "threads": threads.map(threadPayload)])
        case "project.list":
            return ok(id: id, result: projects.map(projectPayload))
        case "thread.list":
            if let projectID = params?["project_id"] as? String {
                return ok(id: id, result: threads.filter { $0.projectID == projectID }.map(threadPayload))
            }
            return ok(id: id, result: threads.map(threadPayload))
        case "preset.start", "terminal.resize", "terminal.detach":
            return ok(id: id, result: NSNull())
        case "terminal.attach":
            let threadID = params?["thread_id"] as? String ?? ""
            let preset = params?["preset"] as? String ?? "terminal"
            let channelID = allocateChannelID()
            attachments[channelID] = (threadID: threadID, preset: preset)
            return ok(id: id, result: ["channel_id": Int(channelID)])
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func allocateChannelID() -> UInt16 {
        defer { nextChannelID = nextChannelID == UInt16.max ? 10 : nextChannelID + 1 }
        return nextChannelID
    }

    private func projectPayload(_ project: MockProject) -> [String: Any] {
        [
            "id": project.id,
            "name": project.name,
            "path": project.path,
            "default_branch": project.defaultBranch,
            "presets": project.presets.map {
                [
                    "name": $0.name,
                    "command": $0.command,
                    "cwd": $0.cwd ?? NSNull(),
                ] as [String: Any]
            },
        ]
    }

    private func threadPayload(_ thread: MockThread) -> [String: Any] {
        [
            "id": thread.id,
            "project_id": thread.projectID,
            "name": thread.name,
            "branch": thread.branch,
            "worktree_path": thread.worktreePath,
            "status": thread.status,
            "source_type": thread.sourceType,
            "created_at": formatter.string(from: thread.createdAt),
            "tmux_session": thread.tmuxSession,
        ]
    }

    private func ok(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
