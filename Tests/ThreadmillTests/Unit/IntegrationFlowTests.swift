import ACPModel
import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class IntegrationFlowTests: XCTestCase {
    func test1AddRepoPersistsProjectViaSync() async throws {
        let harness = try makeHarness()

        _ = try await harness.connection.request(
            method: "project.add",
            params: ["path": "/home/wsl/dev/kevin-courbet/threadmill"],
            timeout: 20
        )
        await harness.syncService.syncFromDaemon()

        let projects = try harness.database.allProjects()
        let project = try XCTUnwrap(projects.first(where: { $0.id == "project-threadmill" }))
        XCTAssertEqual(project.name, "threadmill")
        XCTAssertEqual(project.remotePath, "/home/wsl/dev/kevin-courbet/threadmill")
        XCTAssertEqual(project.defaultBranch, "main")
        XCTAssertNil(project.repoId)
        XCTAssertEqual(try harness.database.allProjects().count, 1)
    }

    func test2CreateThreadForRepoPersistsThreadWithProjectLink() async throws {
        let harness = try makeHarness()

        _ = try await harness.connection.request(
            method: "project.add",
            params: ["path": "/home/wsl/dev/kevin-courbet/threadmill"],
            timeout: 20
        )
        await harness.syncService.syncFromDaemon()

        _ = try await harness.connection.request(
            method: "thread.create",
            params: [
                "project_id": "project-threadmill",
                "name": "feature-acp",
                "source_type": "new_feature",
                "branch": "feature/acp-integration",
            ],
            timeout: 30
        )
        await harness.syncService.syncFromDaemon()

        let threads = try harness.database.threadsForProject(id: "project-threadmill")
        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.projectId, "project-threadmill")
        XCTAssertEqual(thread.name, "feature-acp")
        XCTAssertEqual(thread.branch, "feature/acp-integration")
        XCTAssertEqual(thread.status, .active)
    }

    func test3AttachTwoTerminalsAndStartOpencodePreset() async throws {
        let harness = try makeHarness()

        _ = try await harness.connection.request(
            method: "project.add",
            params: ["path": "/home/wsl/dev/kevin-courbet/threadmill"],
            timeout: 20
        )
        _ = try await harness.connection.request(
            method: "thread.create",
            params: [
                "project_id": "project-threadmill",
                "name": "feature-acp",
                "source_type": "new_feature",
                "branch": "feature/acp-integration",
            ],
            timeout: 30
        )

        let firstAttach = try await harness.connection.request(
            method: "terminal.attach",
            params: ["thread_id": "thread-feature-acp", "preset": "terminal"],
            timeout: 10
        ) as? [String: Any]
        let secondAttach = try await harness.connection.request(
            method: "terminal.attach",
            params: ["thread_id": "thread-feature-acp", "preset": "terminal"],
            timeout: 10
        ) as? [String: Any]

        _ = try await harness.connection.request(
            method: "preset.start",
            params: ["thread_id": "thread-feature-acp", "preset": "opencode"],
            timeout: 20
        )

        XCTAssertEqual(firstAttach?["channel_id"] as? Int, 501)
        XCTAssertEqual(secondAttach?["channel_id"] as? Int, 502)
        XCTAssertEqual(harness.state.startedPresets, ["opencode"])
    }

    func test4ChatSessionSendReceiveUpdatesTimeline() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let agentManager = MockAgentManager()
        agentManager.startResult = .success(611)

        let manager = AgentSessionManager(
            agentManager: agentManager,
            connectionManager: connection,
            projectIDResolver: { threadID in
                threadID == "thread-feature-acp" ? "project-threadmill" : nil
            }
        )

        let startedSessionTask = Task {
            try await manager.startSession(
                agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
                threadID: "thread-feature-acp"
            )
        }

        let didSendInitialize = await waitUntilFrameCount(connection, equals: 1)
        XCTAssertTrue(didSendInitialize)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 611,
                requestFrame: connection.sentBinaryFrames[0],
                result: InitializeResponse(protocolVersion: 1, agentCapabilities: AgentCapabilities())
            )
        )

        let didSendSessionNew = await waitUntilFrameCount(connection, equals: 2)
        XCTAssertTrue(didSendSessionNew)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 611,
                requestFrame: connection.sentBinaryFrames[1],
                result: NewSessionResponse(sessionId: SessionId("acp-session-test"))
            )
        )

        let sessionID = try await startedSessionTask.value
        let conversation = ChatConversation(
            id: "conversation-1",
            threadID: "thread-feature-acp",
            agentSessionID: sessionID,
            agentType: "opencode",
            title: "ACP Integration",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            isArchived: false
        )
        XCTAssertEqual(conversation.agentType, "opencode")

        let viewModel = ChatSessionViewModel(
            agentSessionManager: manager,
            sessionID: sessionID,
            threadID: conversation.threadID,
            availableAgents: [AgentConfig(name: "opencode", command: "opencode", cwd: nil)]
        )

        let sendTask = Task {
            await viewModel.sendPrompt(text: "Ship this integration")
        }

        let didSendPrompt = await waitUntilFrameCount(connection, equals: 3)
        XCTAssertTrue(didSendPrompt)

        let userUpdate = SessionUpdateNotification(
            sessionId: SessionId("acp-session-test"),
            update: .userMessageChunk(.text(TextContent(text: "Ship this integration")))
        )
        let userLine = try makeNotificationLine(method: "session/update", params: userUpdate)
        manager.handleBinaryFrame(makeFrame(channelID: 611, payload: Array(userLine)))

        let agentUpdate = SessionUpdateNotification(
            sessionId: SessionId("acp-session-test"),
            update: .agentMessageChunk(.text(TextContent(text: "Hello world")))
        )
        let agentLine = try makeNotificationLine(method: "session/update", params: agentUpdate)
        manager.handleBinaryFrame(makeFrame(channelID: 611, payload: Array(agentLine)))

        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 611,
                requestFrame: connection.sentBinaryFrames[2],
                result: SessionPromptResponse(stopReason: .endTurn)
            )
        )
        _ = await sendTask.value

        let didFlush = await waitForCondition {
            viewModel.timelineItems.count >= 2
        }
        XCTAssertTrue(didFlush)

        let messages = viewModel.timelineItems.compactMap { item -> MessageTimelineItem? in
            if case let .message(message) = item {
                return message
            }
            return nil
        }
        XCTAssertTrue(messages.contains(where: { $0.role == .user && $0.plainText == "Ship this integration" }))
        XCTAssertTrue(messages.contains(where: { $0.role == .assistant && $0.plainText == "Hello world" }))
    }

    private func makeHarness() throws -> (connection: MockDaemonConnection, database: DatabaseManager, syncService: SyncService, state: FakeSpindleState) {
        let database = try DatabaseManager(databasePath: try makeTempDatabasePath())
        let state = FakeSpindleState()
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, params, _ in
            try state.handle(method: method, params: params)
        }

        let appState = AppState()
        let remoteID = try XCTUnwrap(try database.allRemotes().first?.id)
        let syncService = SyncService(
            connectionManager: connection,
            databaseManager: database,
            appState: appState,
            remoteId: remoteID
        )
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection, remoteID: remoteID),
            databaseManager: database,
            syncService: syncService,
            multiplexer: MockTerminalMultiplexer()
        )

        return (connection, database, syncService, state)
    }

    private func makeTempDatabasePath() throws -> String {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("threadmill.db", isDirectory: false).path
    }

    private func makeResponseFrame<ResultPayload: Encodable>(
        channelID: UInt16,
        requestFrame: Data,
        result: ResultPayload
    ) throws -> Data {
        let request = try decodeRequest(from: requestFrame)
        let response = JSONRPCResponse(
            id: request.id,
            result: try anyCodable(from: result),
            error: nil
        )
        var payload = try JSONEncoder().encode(response)
        payload.append(0x0A)
        return makeFrame(channelID: channelID, payload: Array(payload))
    }

    private func makeNotificationLine<Params: Encodable>(method: String, params: Params) throws -> Data {
        let payload = JSONRPCNotification(method: method, params: try anyCodable(from: params))
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return data
    }

    private func anyCodable<Payload: Encodable>(from payload: Payload) throws -> AnyCodable {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private func decodeRequest(from frame: Data) throws -> JSONRPCRequest {
        let payload = frame.dropFirst(2).dropLast()
        return try JSONDecoder().decode(JSONRPCRequest.self, from: payload)
    }

    private func waitUntilFrameCount(_ connection: MockDaemonConnection, equals expected: Int) async -> Bool {
        await waitForCondition {
            connection.sentBinaryFrames.count == expected
        }
    }

    private func waitForCondition(timeout: Duration = .seconds(5), _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var interval: UInt64 = 1_000_000
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: interval)
            interval = min(interval * 2, 50_000_000)
        }
        return condition()
    }
}

private final class FakeSpindleState {
    var projects: [[String: Any]] = []
    var threads: [[String: Any]] = []
    var nextChannelID = 501
    var startedPresets: [String] = []

    func handle(method: String, params: [String: Any]?) throws -> Any {
        switch method {
        case "project.add":
            let path = params?["path"] as? String ?? "/home/wsl/dev/kevin-courbet/threadmill"
            let project: [String: Any] = [
                "id": "project-threadmill",
                "name": "threadmill",
                "path": path,
                "default_branch": "main",
                "presets": [
                    ["name": "terminal", "command": "$SHELL"],
                    ["name": "opencode", "command": "opencode"],
                ],
            ]
            if let index = projects.firstIndex(where: { ($0["id"] as? String) == "project-threadmill" }) {
                projects[index] = project
            } else {
                projects.append(project)
            }
            return ["id": "project-threadmill"]

        case "project.list":
            return projects

        case "thread.create":
            let projectID = params?["project_id"] as? String ?? "project-threadmill"
            let name = params?["name"] as? String ?? "feature-acp"
            let branch = params?["branch"] as? String ?? "feature/acp-integration"
            let now = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1))
            let thread: [String: Any] = [
                "id": "thread-\(name)",
                "project_id": projectID,
                "name": name,
                "branch": branch,
                "worktree_path": "/home/wsl/dev/.threadmill/threadmill/\(name)",
                "status": "active",
                "source_type": "new_feature",
                "created_at": now,
                "tmux_session": "tm_\(name)",
                "port_offset": 0,
            ]
            if let index = threads.firstIndex(where: { ($0["id"] as? String) == (thread["id"] as? String) }) {
                threads[index] = thread
            } else {
                threads.append(thread)
            }
            return ["id": thread["id"] as? String ?? "thread-feature-acp"]

        case "thread.list":
            return threads

        case "state.snapshot":
            return ["chat_sessions": [[String: Any]]()]

        case "terminal.attach":
            defer { nextChannelID += 1 }
            return ["channel_id": nextChannelID]

        case "preset.start":
            if let preset = params?["preset"] as? String {
                startedPresets.append(preset)
            }
            return ["ok": true]

        default:
            throw TestError.missingStub
        }
    }
}
