import ACPModel
import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class AgentSessionManagerTests: XCTestCase {
    func testSessionRoutesFramesByChannelAndDecodesNewlineDelimitedUpdates() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let manager = AgentSessionManager(connectionManager: connection)

        var receivedUpdates: [SessionUpdateNotification] = []
        manager.attachChannel(channelID: 77, sessionID: "acp-session-1") { update in
            receivedUpdates.append(update)
        }

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

        XCTAssertEqual(receivedUpdates.count, 1)

        let promptTask = Task {
            try await manager.sendPrompt(text: "ship it", channelID: 77, sessionID: "acp-session-1")
        }
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

    func testReconnectClearsChannelsAndScopesFramesToOwningConnection() async throws {
        let primaryConnection = MockDaemonConnection(state: .connected)
        let otherConnection = MockDaemonConnection(state: .connected)
        let manager = AgentSessionManager(connectionManager: primaryConnection)

        var receivedUpdates: [SessionUpdateNotification] = []
        manager.attachChannel(channelID: 88, sessionID: "acp-session-2") { update in
            receivedUpdates.append(update)
        }

        let update = SessionUpdateNotification(
            sessionId: SessionId("acp-session-2"),
            update: .agentMessageChunk(.text(TextContent(text: "reconnected")))
        )
        let updatePayload = try makeNotificationLine(method: "session/update", params: update)

        manager.handleBinaryFrame(makeFrame(channelID: 88, payload: Array(updatePayload)), from: otherConnection)
        XCTAssertTrue(receivedUpdates.isEmpty)

        manager.handleConnectionStateChanged(.disconnected, on: primaryConnection)
        manager.handleBinaryFrame(makeFrame(channelID: 88, payload: Array(updatePayload)), from: primaryConnection)
        XCTAssertTrue(receivedUpdates.isEmpty)
    }

    func testRequestPermissionRequestIsAutoApproved() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let manager = AgentSessionManager(connectionManager: connection)
        manager.attachChannel(channelID: 77, sessionID: "acp-session-1") { _ in }

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
        let manager = AgentSessionManager(connectionManager: connection)
        manager.attachChannel(channelID: 77, sessionID: "acp-session-1") { _ in }

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
        let manager = AgentSessionManager(connectionManager: connection)
        manager.attachChannel(channelID: 77, sessionID: "acp-session-1") { _ in }

        let setModelTask = Task {
            try await manager.setModel(channelID: 77, sessionID: "acp-session-1", modelID: "claude-3-7")
        }
        let didSendSetModel = await waitUntilFrameCount(connection, equals: 1)
        XCTAssertTrue(didSendSetModel)

        let request = try decodeRequest(from: connection.sentBinaryFrames[0])
        XCTAssertEqual(request.method, "session/set_model")
        let params = try XCTUnwrap(request.params)
        let paramsData = try JSONEncoder().encode(params)
        let typedParams = try JSONDecoder().decode(SetModelRequest.self, from: paramsData)
        XCTAssertEqual(typedParams.sessionId.value, "acp-session-1")
        XCTAssertEqual(typedParams.modelId, "claude-3-7")

        try manager.handleBinaryFrame(makeResponseFrame(channelID: 77, requestFrame: connection.sentBinaryFrames[0], result: SetModelResponse(success: true)))
        try await setModelTask.value
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
