import ACPModel
import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class AgentSessionManagerTests: XCTestCase {
    func testSessionRoutesFramesByChannelAndDecodesNewlineDelimitedUpdates() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = chatRequestHandler(channelID: 77)

        let manager = AgentSessionManager(connectionManager: connection)

        let sessionID = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
            threadID: "thread-1"
        )

        XCTAssertTrue(connection.requests.contains(where: { $0.method == "chat.start" }))
        XCTAssertTrue(connection.requests.contains(where: { $0.method == "chat.attach" }))

        let update = SessionUpdateNotification(
            sessionId: SessionId(sessionID),
            update: .agentMessageChunk(.text(TextContent(text: "hello")))
        )
        let updatePayload = try makeNotificationLine(method: "session/update", params: update)

        let splitIndex = max(1, updatePayload.count / 2)
        let firstHalf = Data(updatePayload.prefix(splitIndex))
        let secondHalf = Data(updatePayload.dropFirst(splitIndex))
        manager.handleBinaryFrame(makeFrame(channelID: 77, payload: Array(firstHalf)))
        manager.handleBinaryFrame(makeFrame(channelID: 77, payload: Array(secondHalf)))

        XCTAssertEqual(manager.updatesBySessionID[sessionID]?.count, 1)

        let promptTask = Task { try await manager.sendPrompt(text: "ship it", sessionID: sessionID) }
        let didSendPrompt = await waitUntilFrameCount(connection, equals: 1)
        XCTAssertTrue(didSendPrompt)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 77,
                requestFrame: connection.sentBinaryFrames[0],
                result: SessionPromptResponse(stopReason: .endTurn)
            )
        )
        try await promptTask.value
    }

    func testReconnectReattachesSessionAndScopesFramesToOwningConnection() async throws {
        let primaryConnection = MockDaemonConnection(state: .connected)
        let otherConnection = MockDaemonConnection(state: .connected)
        primaryConnection.requestHandler = chatRequestHandler(channelID: 77)

        let manager = AgentSessionManager(connectionManager: primaryConnection)

        let sessionID = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
            threadID: "thread-1"
        )

        manager.handleConnectionStateChanged(.disconnected, on: primaryConnection)

        primaryConnection.requestHandler = chatRequestHandler(channelID: 88, startResult: nil)
        await manager.handleConnectionReconnected(on: primaryConnection)

        let update = SessionUpdateNotification(
            sessionId: SessionId(sessionID),
            update: .agentMessageChunk(.text(TextContent(text: "reconnected")))
        )
        let updatePayload = try makeNotificationLine(method: "session/update", params: update)

        manager.handleBinaryFrame(makeFrame(channelID: 88, payload: Array(updatePayload)), from: otherConnection)
        XCTAssertTrue((manager.updatesBySessionID[sessionID] ?? []).isEmpty)

        manager.handleBinaryFrame(makeFrame(channelID: 88, payload: Array(updatePayload)), from: primaryConnection)
        XCTAssertEqual(manager.updatesBySessionID[sessionID]?.count, 1)

        let promptTask = Task { try await manager.sendPrompt(text: "after reconnect", sessionID: sessionID) }
        let didSendPrompt = await waitUntilFrameCount(primaryConnection, equals: 1)
        XCTAssertTrue(didSendPrompt)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 88,
                requestFrame: primaryConnection.sentBinaryFrames[0],
                result: SessionPromptResponse(stopReason: .endTurn)
            )
        )
        try await promptTask.value
    }

    func testRequestPermissionRequestIsAutoApproved() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = chatRequestHandler(channelID: 77)

        let manager = AgentSessionManager(connectionManager: connection)

        _ = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
            threadID: "thread-1"
        )

        let request = JSONRPCRequest(
            id: .number(99),
            method: "request_permission",
            params: try anyCodable(from: RequestPermissionRequest(
                message: "allow?",
                options: [PermissionOption(kind: "allow", name: "Allow", optionId: "allow-opt")]
            ))
        )
        var requestPayload = try JSONEncoder().encode(request)
        requestPayload.append(0x0A)
        manager.handleBinaryFrame(makeFrame(channelID: 77, payload: Array(requestPayload)))

        let didSendPermissionResponse = await waitUntilFrameCount(connection, equals: 1)
        XCTAssertTrue(didSendPermissionResponse)
        let response = try decodeResponse(from: connection.sentBinaryFrames[0])
        XCTAssertEqual(response.id, .number(99))
        XCTAssertNil(response.error)
        let result = try XCTUnwrap(response.result)
        let resultData = try JSONEncoder().encode(result)
        let permissionResponse = try JSONDecoder().decode(RequestPermissionResponse.self, from: resultData)
        XCTAssertEqual(permissionResponse.outcome.outcome, "selected")
        XCTAssertEqual(permissionResponse.outcome.optionId, "allow-opt")
    }

    func testUnsupportedIncomingRequestReceivesMethodNotFoundError() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = chatRequestHandler(channelID: 77)

        let manager = AgentSessionManager(connectionManager: connection)

        _ = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
            threadID: "thread-1"
        )

        let request = JSONRPCRequest(id: .string("abc"), method: "unknown/method", params: nil)
        var requestPayload = try JSONEncoder().encode(request)
        requestPayload.append(0x0A)
        manager.handleBinaryFrame(makeFrame(channelID: 77, payload: Array(requestPayload)))

        let didSendErrorResponse = await waitUntilFrameCount(connection, equals: 1)
        XCTAssertTrue(didSendErrorResponse)
        let response = try decodeResponse(from: connection.sentBinaryFrames[0])
        XCTAssertEqual(response.id, .string("abc"))
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32601)
    }

    func testSetModelSendsRequestAndConsumesResponse() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = chatRequestHandler(channelID: 77)

        let manager = AgentSessionManager(connectionManager: connection)

        let sessionID = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
            threadID: "thread-1"
        )

        let setModelTask = Task { try await manager.setModel(sessionID: sessionID, modelID: "claude-3-7") }
        let didSendSetModel = await waitUntilFrameCount(connection, equals: 1)
        XCTAssertTrue(didSendSetModel)

        let request = try decodeRequest(from: connection.sentBinaryFrames[0])
        XCTAssertEqual(request.method, "session/set_model")
        let params = try XCTUnwrap(request.params)
        let paramsData = try JSONEncoder().encode(params)
        let typedParams = try JSONDecoder().decode(SetModelRequest.self, from: paramsData)
        XCTAssertEqual(typedParams.sessionId.value, sessionID)
        XCTAssertEqual(typedParams.modelId, "claude-3-7")

        try manager.handleBinaryFrame(makeResponseFrame(channelID: 77, requestFrame: connection.sentBinaryFrames[0], result: SetModelResponse(success: true)))
        try await setModelTask.value
    }

    func testCapabilitiesPopulatedFromChatAttachResponse() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = chatRequestHandler(
            channelID: 77,
            modes: [
                "currentModeId": "code",
                "availableModes": [
                    ["id": "code", "name": "Code"],
                    ["id": "plan", "name": "Plan"],
                ],
            ] as [String: Any],
            models: [
                "currentModelId": "claude-opus",
                "availableModels": [
                    ["modelId": "claude-opus", "name": "Claude Opus"],
                    ["modelId": "claude-sonnet", "name": "Claude Sonnet"],
                ],
            ] as [String: Any]
        )

        let manager = AgentSessionManager(connectionManager: connection)

        let sessionID = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
            threadID: "thread-1"
        )

        let caps = manager.capabilities(for: sessionID)
        XCTAssertEqual(caps.availableModes.count, 2)
        XCTAssertEqual(caps.currentModeID, "code")
        XCTAssertEqual(caps.availableModels.count, 2)
        XCTAssertEqual(caps.currentModelID, "claude-opus")
        XCTAssertEqual(caps.availableModels.first?.name, "Claude Opus")
    }

    // MARK: - Helpers

    /// Creates a requestHandler that responds to chat.start and chat.attach RPCs.
    /// If startResult is nil (reconnect case), chat.start calls throw.
    private func chatRequestHandler(
        channelID: UInt16,
        startResult: String? = "test-session-id",
        modes: [String: Any]? = nil,
        models: [String: Any]? = nil
    ) -> ((String, [String: Any]?, TimeInterval) throws -> Any) {
        var sessionID = startResult ?? "test-session-id"
        return { method, params, _ in
            switch method {
            case "chat.start":
                guard startResult != nil else {
                    throw TestError.missingStub
                }
                return [
                    "session_id": sessionID,
                    "status": "starting",
                ] as [String: Any]
            case "chat.attach":
                if let sid = params?["session_id"] as? String {
                    sessionID = sid
                }
                var result: [String: Any] = [
                    "channel_id": Int(channelID),
                    "acp_session_id": "acp-\(sessionID)",
                ]
                if let modes { result["modes"] = modes }
                if let models { result["models"] = models }
                return result
            case "chat.stop":
                return ["archived": true] as [String: Any]
            default:
                throw TestError.missingStub
            }
        }
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

    private func decodeResponse(from frame: Data) throws -> JSONRPCResponse {
        let payload = frame.dropFirst(2).dropLast()
        return try JSONDecoder().decode(JSONRPCResponse.self, from: payload)
    }

    private func waitUntilFrameCount(_ connection: MockDaemonConnection, equals expected: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if connection.sentBinaryFrames.count == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return connection.sentBinaryFrames.count == expected
    }
}
