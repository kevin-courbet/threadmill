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
    private let formatter: ISO8601DateFormatter

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    private var projects: [MockProject]
    private var threads: [MockThread]
    private var attachments: [UInt16: (threadID: String, preset: String)] = [:]
    private var nextChannelID: UInt16 = 10

    private(set) var port: UInt16 = 0

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
                tmuxSession: "tm_project-main_bootstrap-thread"
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
        clients.removeValue(forKey: ObjectIdentifier(client))
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
        let handled = handle(method: method, id: id, params: params)
        client.sendJSON(handled.response)
        for event in handled.events {
            broadcast(event)
        }
    }

    private func handle(method: String, id: Any, params: [String: Any]?) -> (response: [String: Any], events: [[String: Any]]) {
        switch method {
        case "ping":
            return (ok(id: id, result: "pong"), [])

        case "project.list":
            return (ok(id: id, result: projects.map(projectPayload)), [])

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
            let event: [String: Any] = ["method": "project.added", "params": ["project_id": project.id]]
            return (ok(id: id, result: projectPayload(project)), [event])

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
                tmuxSession: "tm_\(projectID)_\(slug(name))"
            )
            threads.insert(thread, at: 0)

            let progress: [String: Any] = [
                "method": "thread.progress",
                "params": ["thread_id": thread.id, "step": "create", "message": "mock create", "error": NSNull()],
            ]
            let statusChanged: [String: Any] = [
                "method": "thread.status_changed",
                "params": ["thread_id": thread.id, "old": "creating", "new": "active"],
            ]
            let created: [String: Any] = ["method": "thread.created", "params": ["thread_id": thread.id]]
            return (ok(id: id, result: ["thread_id": thread.id]), [progress, statusChanged, created])

        case "thread.hide":
            let threadID = params?["thread_id"] as? String ?? ""
            guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
                return (error(id: id, code: -1, message: "thread not found"), [])
            }
            let old = threads[index].status
            threads[index].status = "hidden"
            let event: [String: Any] = [
                "method": "thread.status_changed",
                "params": ["thread_id": threadID, "old": old, "new": "hidden"],
            ]
            return (ok(id: id, result: NSNull()), [event])

        case "thread.reopen":
            let threadID = params?["thread_id"] as? String ?? ""
            guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
                return (error(id: id, code: -1, message: "thread not found"), [])
            }
            let old = threads[index].status
            threads[index].status = "active"
            let event: [String: Any] = [
                "method": "thread.status_changed",
                "params": ["thread_id": threadID, "old": old, "new": "active"],
            ]
            return (ok(id: id, result: NSNull()), [event])

        case "thread.close":
            let threadID = params?["thread_id"] as? String ?? ""
            threads.removeAll { $0.id == threadID }
            attachments = attachments.filter { $0.value.threadID != threadID }
            let event: [String: Any] = ["method": "thread.removed", "params": ["thread_id": threadID]]
            return (ok(id: id, result: NSNull()), [event])

        case "preset.start", "terminal.resize":
            return (ok(id: id, result: NSNull()), [])

        case "terminal.attach":
            let threadID = params?["thread_id"] as? String ?? ""
            let preset = params?["preset"] as? String ?? "terminal"
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
            return (error(id: id, code: -32601, message: "Method not found: \(method)"), [])
        }
    }

    private func broadcast(_ payload: [String: Any]) {
        for client in clients.values {
            client.sendJSON(payload)
        }
    }

    private func allocateChannelID() -> UInt16 {
        defer { nextChannelID = nextChannelID == UInt16.max ? 10 : nextChannelID + 1 }
        return nextChannelID
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
        ]
    }

    private func ok(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
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
}
