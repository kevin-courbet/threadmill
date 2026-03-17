import Foundation
import Network

final class MockSpindleServer {
    private struct MockPreset {
        var name: String
        var command: String
        var cwd: String?
    }

    private struct MockProject {
        var id: String
        var name: String
        var path: String
        var defaultBranch: String
        var presets: [MockPreset]
    }

    private struct MockThread {
        var id: String
        var projectID: String
        var name: String
        var branch: String
        var worktreePath: String
        var status: String
        var sourceType: String
        var createdAt: Date
        var tmuxSession: String
        var portOffset: Int
    }

    struct RPCRequest {
        var method: String
        var params: [String: Any]?
    }

    private final class ClientConnection {
        let connection: NWConnection

        private let queue: DispatchQueue
        private let onMessage: (NWProtocolWebSocket.Opcode, Data, ClientConnection) -> Void
        private let onClose: (ClientConnection) -> Void

        init(
            connection: NWConnection,
            queue: DispatchQueue,
            onMessage: @escaping (NWProtocolWebSocket.Opcode, Data, ClientConnection) -> Void,
            onClose: @escaping (ClientConnection) -> Void
        ) {
            self.connection = connection
            self.queue = queue
            self.onMessage = onMessage
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    return
                }
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
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let text = String(data: data, encoding: .utf8)
            else {
                return
            }
            send(opcode: .text, payload: Data(text.utf8))
        }

        func sendBinary(_ payload: Data) {
            send(opcode: .binary, payload: payload)
        }

        private func send(opcode: NWProtocolWebSocket.Opcode, payload: Data) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(identifier: "mock-ws-send", metadata: [metadata])
            connection.send(content: payload, contentContext: context, isComplete: true, completion: .idempotent)
        }

        private func receiveNextMessage() {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self else {
                    return
                }

                if let error {
                    NSLog("mock-spindle: receive error: %@", "\(error)")
                    self.onClose(self)
                    return
                }

                if let context,
                   let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   let data {
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

    private let queue = DispatchQueue(label: "threadmill.mock-spindle")
    private static let protocolVersion = "2026-03-17"
    private static let requiredClientCapabilities = [
        "state.delta.operations.v1",
        "preset.output.v1",
        "rpc.errors.structured.v1",
    ]
    private static let supportedCapabilities = [
        "state.delta.operations.v1",
        "preset.output.v1",
        "rpc.errors.structured.v1",
    ]
    private let formatter: ISO8601DateFormatter

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    private var projects: [MockProject]
    private var threads: [MockThread]
    private var attachments: [UInt16: (threadID: String, preset: String)] = [:]
    private var clientSessionIDs: [ObjectIdentifier: String] = [:]
    private var requestLog: [RPCRequest] = []
    private var stateVersion = 1
    private var nextChannelID: UInt16 = 10
    private var nextOperationID = 1

    private(set) var port: UInt16 = 0

    func requestCount(method: String) -> Int {
        queue.sync {
            requestLog.filter { $0.method == method }.count
        }
    }

    func lastRequestParams(method: String) -> [String: Any]? {
        queue.sync {
            requestLog.last(where: { $0.method == method })?.params
        }
    }

    func requestParams(method: String) -> [[String: Any]] {
        queue.sync {
            requestLog
                .filter { $0.method == method }
                .compactMap(\.params)
        }
    }

    init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        projects = [
            MockProject(
                id: "project-main",
                name: "myautonomy",
                path: "/home/wsl/dev/myautonomy",
                defaultBranch: "main",
                presets: [
                    MockPreset(name: "editor", command: "nvim", cwd: nil),
                    MockPreset(name: "shell", command: "bash", cwd: nil),
                ]
            ),
        ]

        threads = [
            MockThread(
                id: "thread-main",
                projectID: "project-main",
                name: "bootstrap-thread",
                branch: "feature/bootstrap",
                worktreePath: "/home/wsl/dev/.threadmill/myautonomy/bootstrap-thread",
                status: "active",
                sourceType: "new_feature",
                createdAt: Date(),
                tmuxSession: "tm_project-main_bootstrap-thread",
                portOffset: 0
            ),
        ]
    }

    func start() throws {
        if listener != nil {
            return
        }

        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.accept(connection: connection)
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var startupError: Error?
        var signaled = false

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }

            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                if !signaled {
                    signaled = true
                    semaphore.signal()
                }
            case let .failed(error):
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
            clientSessionIDs.removeAll()
            requestLog.removeAll()
            stateVersion = 1
            nextOperationID = 1
            listener?.cancel()
            listener = nil
            port = 0
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
                self?.disconnect(client: client)
            }
        )
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    private func disconnect(client: ClientConnection) {
        let clientID = ObjectIdentifier(client)
        clients.removeValue(forKey: clientID)
        clientSessionIDs.removeValue(forKey: clientID)
    }

    private func handle(opcode: NWProtocolWebSocket.Opcode, payload: Data, from client: ClientConnection) {
        switch opcode {
        case .text:
            handleJSONFrame(payload, from: client)
        case .binary:
            client.sendBinary(payload)
        case .close:
            disconnect(client: client)
        default:
            break
        }
    }

    private func handleJSONFrame(_ payload: Data, from client: ClientConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: payload, options: []),
              let request = object as? [String: Any],
              let id = request["id"],
              let method = request["method"] as? String
        else {
            return
        }

        let params = request["params"] as? [String: Any]
        requestLog.append(RPCRequest(method: method, params: params))
        let handled = handle(method: method, id: id, params: params, from: client)
        client.sendJSON(handled.response)
        for event in handled.events {
            broadcast(event)
        }
    }

    private func handle(
        method: String,
        id: Any,
        params: [String: Any]?,
        from client: ClientConnection
    ) -> (response: [String: Any], events: [[String: Any]]) {
        let clientID = ObjectIdentifier(client)

        if method == "session.hello", clientSessionIDs[clientID] != nil {
            return (
                error(
                    id: id,
                    code: -32600,
                    message: "session.hello may only be called once per connection",
                    kind: "session.already_initialized",
                    retryable: false
                ),
                []
            )
        }

        switch method {
        case "session.hello":
            return handleSessionHello(id: id, params: params, clientID: clientID)

        case "ping":
            return (ok(id: id, result: "pong"), [])

        default:
            guard clientSessionIDs[clientID] != nil else {
                return (
                    error(
                        id: id,
                        code: -32000,
                        message: "session.hello required before calling \(method)",
                        kind: "session.not_initialized",
                        retryable: false,
                        details: ["method": method]
                    ),
                    []
                )
            }
            return handleSessionMethod(method: method, id: id, params: params)
        }
    }

    private func handleSessionMethod(method: String, id: Any, params: [String: Any]?) -> (response: [String: Any], events: [[String: Any]]) {
        switch method {

        case "state.snapshot":
            return (ok(id: id, result: stateSnapshotPayload()), [])

        case "system.stats":
            return (
                ok(
                    id: id,
                    result: [
                        "load_avg_1m": 0.42,
                        "memory_total_mb": 32768,
                        "memory_used_mb": 16384,
                        "opencode_instances": 1,
                    ]
                ),
                []
            )

        case "project.list":
            return (ok(id: id, result: projects.map(projectPayload)), [])

        case "project.lookup":
            let path = params?["path"] as? String ?? ""
            if let project = projects.first(where: { $0.path == path }) {
                return (
                    ok(
                        id: id,
                        result: [
                            "exists": true,
                            "is_git_repo": true,
                            "project_id": project.id,
                        ]
                    ),
                    []
                )
            }
            return (
                ok(
                    id: id,
                    result: [
                        "exists": false,
                        "is_git_repo": false,
                        "project_id": NSNull(),
                    ]
                ),
                []
            )

        case "project.browse":
            let path = params?["path"] as? String ?? "/home/wsl/dev"
            let result: [[String: Any]] = [
                ["name": "myautonomy", "is_dir": true, "path": "\(path)/myautonomy"],
                ["name": "tigerdata", "is_dir": true, "path": "\(path)/tigerdata"],
                ["name": "factorio", "is_dir": true, "path": "\(path)/factorio"],
            ]
            return (ok(id: id, result: result), [])

        case "project.add":
            let path = params?["path"] as? String ?? "/home/wsl/dev/project"
            let name = URL(fileURLWithPath: path).lastPathComponent
            let project = MockProject(
                id: uniqueProjectID(for: name),
                name: name,
                path: path,
                defaultBranch: "main",
                presets: [
                    MockPreset(name: "editor", command: "nvim", cwd: nil),
                    MockPreset(name: "shell", command: "bash", cwd: nil),
                ]
            )
            projects.append(project)
            stateVersion += 1
            let event: [String: Any] = ["method": "project.added", "params": ["project": projectPayload(project)]]
            let delta = stateDeltaEvent(operations: [["type": "project.added", "project": projectPayload(project)]])
            return (ok(id: id, result: projectPayload(project)), [event, delta])

        case "project.clone":
            let url = params?["url"] as? String ?? "https://github.com/example/project.git"
            let repoName = repoNameFromCloneURL(url)
            let project = MockProject(
                id: uniqueProjectID(for: repoName),
                name: repoName,
                path: "/home/wsl/dev/\(repoName)",
                defaultBranch: "main",
                presets: [
                    MockPreset(name: "terminal", command: "bash", cwd: nil),
                    MockPreset(name: "dev-server", command: "bun run dev", cwd: nil),
                ]
            )
            projects.append(project)
            stateVersion += 1
            let event: [String: Any] = ["method": "project.added", "params": ["project": projectPayload(project)]]
            let delta = stateDeltaEvent(operations: [["type": "project.added", "project": projectPayload(project)]])
            return (ok(id: id, result: projectPayload(project)), [event, delta])

        case "project.remove":
            let projectID = params?["project_id"] as? String ?? ""
            let hadProject = projects.contains(where: { $0.id == projectID })
            projects.removeAll { $0.id == projectID }
            threads.removeAll { $0.projectID == projectID }
            if hadProject {
                stateVersion += 1
                let event: [String: Any] = ["method": "project.removed", "params": ["project_id": projectID]]
                let delta = stateDeltaEvent(operations: [["type": "project.removed", "project_id": projectID]])
                return (ok(id: id, result: ["removed": true]), [event, delta])
            }
            return (ok(id: id, result: ["removed": false]), [])

        case "project.branches":
            return (ok(id: id, result: ["main", "develop", "release/test"]), [])

        case "thread.list":
            if let projectID = params?["project_id"] as? String {
                let rows = threads.filter { $0.projectID == projectID }.map(threadPayload)
                return (ok(id: id, result: rows), [])
            }
            return (ok(id: id, result: threads.map(threadPayload)), [])

        case "thread.create":
            let projectID = params?["project_id"] as? String ?? projects.first?.id ?? "project-main"
            let name = params?["name"] as? String ?? "new-thread"
            let sourceType = params?["source_type"] as? String ?? "new_feature"
            let branch = (params?["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name

            let thread = MockThread(
                id: uniqueThreadID(for: name),
                projectID: projectID,
                name: name,
                branch: branch,
                worktreePath: "/home/wsl/dev/.threadmill/\(projectID)/\(slug(name))",
                status: "active",
                sourceType: sourceType,
                createdAt: Date(),
                tmuxSession: "tm_\(projectID)_\(slug(name))",
                portOffset: nextPortOffset(for: projectID)
            )
            threads.insert(thread, at: 0)
            stateVersion += 1

            let progress: [String: Any] = [
                "method": "thread.progress",
                "params": ["thread_id": thread.id, "step": "creating_worktree", "message": "mock create", "error": NSNull()],
            ]
            let statusChanged: [String: Any] = [
                "method": "thread.status_changed",
                "params": ["thread_id": thread.id, "old": "creating", "new": "active"],
            ]
            let created: [String: Any] = ["method": "thread.created", "params": ["thread": threadPayload(thread)]]
            let delta = stateDeltaEvent(operations: [[
                "type": "thread.status_changed",
                "thread_id": thread.id,
                "old": "creating",
                "new": "active",
            ]])
            return (ok(id: id, result: threadPayload(thread)), [progress, statusChanged, created, delta])

        case "thread.hide":
            let threadID = params?["thread_id"] as? String ?? ""
            guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
                return (error(id: id, code: -32004, message: "thread not found", kind: "thread.not_found"), [])
            }
            let old = threads[index].status
            threads[index].status = "hidden"
            stateVersion += 1
            let event: [String: Any] = [
                "method": "thread.status_changed",
                "params": ["thread_id": threadID, "old": old, "new": "hidden"],
            ]
            let delta = stateDeltaEvent(operations: [[
                "type": "thread.status_changed",
                "thread_id": threadID,
                "old": old,
                "new": "hidden",
            ]])
            return (ok(id: id, result: NSNull()), [event, delta])

        case "thread.reopen":
            let threadID = params?["thread_id"] as? String ?? ""
            guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
                return (error(id: id, code: -32004, message: "thread not found", kind: "thread.not_found"), [])
            }
            let old = threads[index].status
            threads[index].status = "active"
            stateVersion += 1
            let event: [String: Any] = [
                "method": "thread.status_changed",
                "params": ["thread_id": threadID, "old": old, "new": "active"],
            ]
            let delta = stateDeltaEvent(operations: [[
                "type": "thread.status_changed",
                "thread_id": threadID,
                "old": old,
                "new": "active",
            ]])
            return (ok(id: id, result: NSNull()), [event, delta])

        case "thread.close":
            let threadID = params?["thread_id"] as? String ?? ""
            let didRemove = threads.contains(where: { $0.id == threadID })
            threads.removeAll { $0.id == threadID }
            attachments = attachments.filter { $0.value.threadID != threadID }
            if didRemove {
                stateVersion += 1
            }
            let event: [String: Any] = ["method": "thread.removed", "params": ["thread_id": threadID]]
            let delta = stateDeltaEvent(operations: [["type": "thread.removed", "thread_id": threadID]])
            return (ok(id: id, result: NSNull()), [event, delta])

        case "preset.start":
            let threadID = params?["thread_id"] as? String ?? ""
            let preset = params?["preset"] as? String ?? "terminal"
            let processEvent: [String: Any] = [
                "method": "preset.process_event",
                "params": ["thread_id": threadID, "preset": preset, "event": "started"],
            ]
            let outputEvent: [String: Any] = [
                "method": "preset.output",
                "params": [
                    "thread_id": threadID,
                    "preset": preset,
                    "stream": "stdout",
                    "chunk": "\(preset) started",
                ],
            ]
            let delta = stateDeltaEvent(operations: [[
                "type": "preset.process_event",
                "thread_id": threadID,
                "preset": preset,
                "event": "started",
            ]])
            return (ok(id: id, result: NSNull()), [processEvent, outputEvent, delta])

        case "terminal.resize", "preset.stop", "preset.restart":
            return (ok(id: id, result: NSNull()), [])

        case "terminal.attach":
            let threadID = params?["thread_id"] as? String ?? ""
            let preset = params?["preset"] as? String ?? "terminal"
            guard threads.contains(where: { $0.id == threadID }) else {
                return (
                    error(
                        id: id,
                        code: -32004,
                        message: "thread not found: \(threadID)",
                        kind: "resource.not_found"
                    ),
                    []
                )
            }
            let channelID = allocateChannelID()
            attachments[channelID] = (threadID: threadID, preset: preset)
            return (ok(id: id, result: ["channel_id": Int(channelID)]), [])

        case "terminal.detach":
            let threadID = params?["thread_id"] as? String ?? ""
            let preset = params?["preset"] as? String ?? ""
            if let channelID = attachments.first(where: { $0.value.threadID == threadID && $0.value.preset == preset })?.key {
                attachments.removeValue(forKey: channelID)
            }
            return (ok(id: id, result: NSNull()), [])

        default:
            return (error(id: id, code: -32601, message: "Method not found: \(method)", kind: "rpc.method_not_found"), [])
        }
    }

    private func broadcast(_ payload: [String: Any]) {
        for (clientID, client) in clients {
            guard clientSessionIDs[clientID] != nil else {
                continue
            }
            client.sendJSON(payload)
        }
    }

    private func allocateChannelID() -> UInt16 {
        defer { nextChannelID = nextChannelID == UInt16.max ? 10 : nextChannelID + 1 }
        return nextChannelID
    }

    private func stateSnapshotPayload() -> [String: Any] {
        [
            "state_version": stateVersion,
            "projects": projects.map(projectPayload),
            "threads": threads.map(threadPayload),
        ]
    }

    private func projectPayload(_ project: MockProject) -> [String: Any] {
        let presets = project.presets.map { preset in
            [
                "name": preset.name,
                "command": preset.command,
                "cwd": preset.cwd ?? NSNull(),
            ] as [String: Any]
        }

        return [
            "id": project.id,
            "name": project.name,
            "path": project.path,
            "default_branch": project.defaultBranch,
            "presets": presets,
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
            "port_offset": thread.portOffset,
        ]
    }

    private func ok(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(
        id: Any,
        code: Int,
        message: String,
        kind: String? = nil,
        retryable: Bool? = nil,
        details: [String: Any]? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]

        var data: [String: Any] = [:]
        if let kind {
            data["kind"] = kind
        }
        if let retryable {
            data["retryable"] = retryable
        }
        if let details {
            data["details"] = details
        }

        if !data.isEmpty, var errorBody = payload["error"] as? [String: Any] {
            errorBody["data"] = data
            payload["error"] = errorBody
        }

        return payload
    }

    private func handleSessionHello(id: Any, params: [String: Any]?, clientID: ObjectIdentifier) -> (response: [String: Any], events: [[String: Any]]) {
        guard let params,
              params["client"] is [String: Any],
              let protocolVersion = params["protocol_version"] as? String,
              let requestedCapabilities = params["capabilities"] as? [String]
        else {
            return (
                error(
                    id: id,
                    code: -32602,
                    message: "invalid session.hello params",
                    kind: "rpc.invalid_params",
                    retryable: false
                ),
                []
            )
        }

        if protocolVersion != Self.protocolVersion {
            return (
                error(
                    id: id,
                    code: -32602,
                    message: "unsupported protocol_version '\(protocolVersion)', expected '\(Self.protocolVersion)'",
                    kind: "session.protocol_mismatch",
                    retryable: false,
                    details: [
                        "client_protocol_version": protocolVersion,
                        "expected_protocol_version": Self.protocolVersion,
                    ]
                ),
                []
            )
        }

        let requiredCapabilities = (params["required_capabilities"] as? [String]) ?? requestedCapabilities
        let unsupportedRequiredCapabilities = requiredCapabilities.filter { required in
            !Self.supportedCapabilities.contains(required)
        }
        if !unsupportedRequiredCapabilities.isEmpty {
            return (
                error(
                    id: id,
                    code: -32602,
                    message: "missing required capabilities: \(unsupportedRequiredCapabilities.joined(separator: ", "))",
                    kind: "session.missing_capabilities",
                    retryable: false,
                    details: ["missing": unsupportedRequiredCapabilities]
                ),
                []
            )
        }

        let missingCapabilities = Self.requiredClientCapabilities.filter { required in
            !requestedCapabilities.contains(required)
        }
        if !missingCapabilities.isEmpty {
            return (
                error(
                    id: id,
                    code: -32602,
                    message: "missing required capabilities: \(missingCapabilities.joined(separator: ", "))",
                    kind: "session.missing_capabilities",
                    retryable: false,
                    details: ["missing": missingCapabilities]
                ),
                []
            )
        }

        let sessionID = "mock-session-\(UUID().uuidString.lowercased())"
        clientSessionIDs[clientID] = sessionID
        let negotiated = requestedCapabilities.filter { Self.supportedCapabilities.contains($0) }

        return (
            ok(
                id: id,
                result: [
                    "session_id": sessionID,
                    "protocol_version": Self.protocolVersion,
                    "capabilities": negotiated,
                    "required_capabilities": Self.requiredClientCapabilities,
                    "state_version": stateVersion,
                ]
            ),
            []
        )
    }

    private func stateDeltaEvent(operations: [[String: Any]]) -> [String: Any] {
        let numberedOperations = operations.map { operation -> [String: Any] in
            if operation["op_id"] != nil {
                return operation
            }
            var withID = operation
            withID["op_id"] = "op-\(nextOperationID)"
            nextOperationID += 1
            return withID
        }

        return [
            "method": "state.delta",
            "params": [
                "state_version": stateVersion,
                "operations": numberedOperations,
            ],
        ]
    }

    private func nextPortOffset(for projectID: String) -> Int {
        let used = Set(threads.filter { $0.projectID == projectID }.map(\.portOffset))
        var candidate = 0
        while used.contains(candidate) {
            candidate += 20
        }
        return candidate
    }

    private func uniqueProjectID(for name: String) -> String {
        let base = "project-\(slug(name))"
        var candidate = base
        var index = 2
        while projects.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private func uniqueThreadID(for name: String) -> String {
        let base = "thread-\(slug(name))"
        var candidate = base
        var index = 2
        while threads.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private func slug(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return "item"
        }

        return trimmed
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: "--", with: "-")
    }

    private func repoNameFromCloneURL(_ url: String) -> String {
        if let parsedURL = URL(string: url), let host = parsedURL.host, !host.isEmpty {
            let name = parsedURL.deletingPathExtension().lastPathComponent
            if !name.isEmpty {
                return name
            }
        }

        let pathLike = url
            .split(separator: ":")
            .last
            .map(String.init) ?? url
        let component = pathLike
            .split(separator: "/")
            .last
            .map(String.init) ?? "project"
        let trimmed = component.hasSuffix(".git") ? String(component.dropLast(4)) : component
        return trimmed.isEmpty ? "project" : trimmed
    }
}
