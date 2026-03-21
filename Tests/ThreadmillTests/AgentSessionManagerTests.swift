import ACPModel
import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class AgentSessionManagerTests: XCTestCase {
    func testSessionRoutesFramesByChannelAndDecodesNewlineDelimitedUpdates() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let agentManager = MockAgentManager()
        agentManager.startResult = .success(77)

        let manager = AgentSessionManager(
            agentManager: agentManager,
            connectionManager: connection,
            projectIDResolver: { threadID in
                threadID == "thread-1" ? "project-1" : nil
            }
        )

        let startTask = Task { try await manager.startSession(agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil), threadID: "thread-1") }

        let didSendInit = await waitUntilFrameCount(connection, equals: 1)
        XCTAssertTrue(didSendInit)
        try manager.handleBinaryFrame(makeResponseFrame(channelID: 77, requestFrame: connection.sentBinaryFrames[0], result: InitializeResponse(protocolVersion: 1, agentCapabilities: AgentCapabilities())))

        let didSendSessionNew = await waitUntilFrameCount(connection, equals: 2)
        XCTAssertTrue(didSendSessionNew)
        try manager.handleBinaryFrame(makeResponseFrame(channelID: 77, requestFrame: connection.sentBinaryFrames[1], result: NewSessionResponse(sessionId: SessionId("acp-session-1"))))

        let sessionID = try await startTask.value
        XCTAssertEqual(agentManager.startedAgents.first?.projectID, "project-1")
        XCTAssertEqual(agentManager.startedAgents.first?.agentName, "opencode")

        let update = SessionUpdateNotification(
            sessionId: SessionId("acp-session-1"),
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
        let didSendPrompt = await waitUntilFrameCount(connection, equals: 3)
        XCTAssertTrue(didSendPrompt)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 77,
                requestFrame: connection.sentBinaryFrames[2],
                result: SessionPromptResponse(stopReason: .endTurn)
            )
        )
        try await promptTask.value
    }

    func testReconnectReattachesSessionAndScopesFramesToOwningConnection() async throws {
        let primaryConnection = MockDaemonConnection(state: .connected)
        let otherConnection = MockDaemonConnection(state: .connected)
        let agentManager = MockAgentManager()
        agentManager.startResult = .success(77)

        let manager = AgentSessionManager(
            agentManager: agentManager,
            connectionManager: primaryConnection,
            projectIDResolver: { threadID in
                threadID == "thread-1" ? "project-1" : nil
            }
        )

        let startTask = Task {
            try await manager.startSession(
                agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
                threadID: "thread-1"
            )
        }

        let didSendInit = await waitUntilFrameCount(primaryConnection, equals: 1)
        XCTAssertTrue(didSendInit)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 77,
                requestFrame: primaryConnection.sentBinaryFrames[0],
                result: InitializeResponse(protocolVersion: 1, agentCapabilities: AgentCapabilities())
            )
        )

        let didSendSessionNew = await waitUntilFrameCount(primaryConnection, equals: 2)
        XCTAssertTrue(didSendSessionNew)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 77,
                requestFrame: primaryConnection.sentBinaryFrames[1],
                result: NewSessionResponse(sessionId: SessionId("acp-session-1"))
            )
        )

        let sessionID = try await startTask.value

        manager.handleConnectionStateChanged(.disconnected, on: primaryConnection)

        agentManager.startResult = .success(88)
        let reconnectTask = Task {
            await manager.handleConnectionReconnected(on: primaryConnection)
        }

        let didSendReconnectInit = await waitUntilFrameCount(primaryConnection, equals: 3)
        XCTAssertTrue(didSendReconnectInit)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 88,
                requestFrame: primaryConnection.sentBinaryFrames[2],
                result: InitializeResponse(protocolVersion: 1, agentCapabilities: AgentCapabilities())
            )
        )

        let didSendReconnectSessionNew = await waitUntilFrameCount(primaryConnection, equals: 4)
        XCTAssertTrue(didSendReconnectSessionNew)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 88,
                requestFrame: primaryConnection.sentBinaryFrames[3],
                result: NewSessionResponse(sessionId: SessionId("acp-session-2"))
            )
        )

        _ = await reconnectTask.value

        let update = SessionUpdateNotification(
            sessionId: SessionId("acp-session-2"),
            update: .agentMessageChunk(.text(TextContent(text: "reconnected")))
        )
        let updatePayload = try makeNotificationLine(method: "session/update", params: update)

        manager.handleBinaryFrame(makeFrame(channelID: 88, payload: Array(updatePayload)), from: otherConnection)
        XCTAssertTrue((manager.updatesBySessionID[sessionID] ?? []).isEmpty)

        manager.handleBinaryFrame(makeFrame(channelID: 88, payload: Array(updatePayload)), from: primaryConnection)
        XCTAssertEqual(manager.updatesBySessionID[sessionID]?.count, 1)

        let promptTask = Task { try await manager.sendPrompt(text: "after reconnect", sessionID: sessionID) }
        let didSendPrompt = await waitUntilFrameCount(primaryConnection, equals: 5)
        XCTAssertTrue(didSendPrompt)
        try manager.handleBinaryFrame(
            makeResponseFrame(
                channelID: 88,
                requestFrame: primaryConnection.sentBinaryFrames[4],
                result: SessionPromptResponse(stopReason: .endTurn)
            )
        )
        try await promptTask.value
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
        for _ in 0 ..< 100 {
            if connection.sentBinaryFrames.count == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return connection.sentBinaryFrames.count == expected
    }
}
