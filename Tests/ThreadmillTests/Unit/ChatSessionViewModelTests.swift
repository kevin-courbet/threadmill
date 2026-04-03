import ACPModel
import XCTest
@testable import Threadmill

@MainActor
final class ChatSessionViewModelTests: XCTestCase {
    func testInitHydratesTimelineFromChatHistoryWhenSessionExists() async throws {
        let connection = MockDaemonConnection(state: .connected)
        var historyCallCount = 0
        connection.requestHandler = { method, params, _ in
            switch method {
            case "chat.start":
                return ["session_id": "session-1"] as [String: Any]
            case "chat.attach":
                return ["channel_id": 611, "acp_session_id": "session-1"] as [String: Any]
            case "chat.history":
                historyCallCount += 1
                let cursor = params?["cursor"] as? UInt64
                if cursor == nil {
                    return try Self.makeHistoryPayload(
                        updates: [
                            SessionUpdateNotification(
                                sessionId: SessionId("session-1"),
                                update: .userMessageChunk(.text(TextContent(text: "hello")))
                            ),
                        ],
                        nextCursor: 42
                    )
                }

                return try Self.makeHistoryPayload(
                    updates: [
                        SessionUpdateNotification(
                            sessionId: SessionId("session-1"),
                            update: .agentMessageChunk(.text(TextContent(text: "world")))
                        ),
                    ],
                    nextCursor: nil
                )
            default:
                throw TestError.missingStub
            }
        }

        let manager = AgentSessionManager(connectionManager: connection)
        _ = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode", cwd: nil),
            threadID: "thread-1"
        )

        let viewModel = ChatSessionViewModel(
            agentSessionManager: manager,
            sessionID: "session-1",
            threadID: "thread-1"
        )

        let didHydrate = await waitForCondition {
            viewModel.timelineItems.count >= 2 && viewModel.isHydrated
        }

        XCTAssertTrue(didHydrate)
        XCTAssertEqual(historyCallCount, 2)

        viewModel.updateSessionContext(sessionID: "session-1", sessionState: .ready)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(historyCallCount, 2)
    }

    func testSelectAgentUpdatesSelectionWhenNotStreaming() async {
        let viewModel = ChatSessionViewModel(
            agentSessionManager: nil,
            selectedAgentName: "opencode",
            availableAgents: [
                AgentConfig(name: "opencode", command: "opencode", cwd: nil),
                AgentConfig(name: "claude", command: "claude", cwd: nil),
            ]
        )

        await viewModel.selectAgent(named: "claude")

        XCTAssertEqual(viewModel.selectedAgentName, "claude")
    }

    func testSelectAgentDoesNotChangeWhileStreaming() async {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil, selectedAgentName: "opencode")
        viewModel.isStreaming = true

        await viewModel.selectAgent(named: "claude")

        XCTAssertEqual(viewModel.selectedAgentName, "opencode")
    }

    func testCycleModeForwardLoopsThroughModes() async {
        let modes = [
            ModeInfo(id: "chat", name: "Chat"),
            ModeInfo(id: "code", name: "Code"),
            ModeInfo(id: "plan", name: "Plan"),
        ]
        let viewModel = ChatSessionViewModel(agentSessionManager: nil, availableModes: modes)

        await viewModel.cycleModeForward()
        XCTAssertEqual(viewModel.currentMode, "code")

        await viewModel.cycleModeForward()
        XCTAssertEqual(viewModel.currentMode, "plan")

        await viewModel.cycleModeForward()
        XCTAssertEqual(viewModel.currentMode, "chat")
    }

    func testInputEnabledDependsOnSessionState() {
        let viewModel = ChatSessionViewModel(
            agentSessionManager: nil,
            sessionID: nil,
            sessionState: .starting,
            threadID: "thread-1"
        )

        XCTAssertFalse(viewModel.isInputEnabled)

        viewModel.updateSessionContext(sessionID: "session-1", sessionState: .ready)
        XCTAssertFalse(viewModel.isInputEnabled)

        viewModel.updateSessionContext(sessionID: "session-1", sessionState: .failed(TestError.forcedFailure))
        XCTAssertFalse(viewModel.isInputEnabled)
    }

    func testHandleSessionUpdatePlanStoresCurrentPlan() {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil)
        let plan = Plan(entries: [
            PlanEntry(content: "Investigate issue", priority: .high, status: .inProgress),
            PlanEntry(content: "Ship fix", priority: .medium, status: .pending),
        ])

        viewModel.handleSessionUpdate(
            SessionUpdateNotification(
                sessionId: SessionId("session-1"),
                update: .plan(plan)
            )
        )

        XCTAssertEqual(viewModel.currentPlan, plan)
    }

    func testSessionChangeClearsCurrentPlan() {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil, sessionID: "session-1", sessionState: .ready)
        viewModel.currentPlan = Plan(entries: [
            PlanEntry(content: "Persisted task", priority: .low, status: .pending),
        ])

        viewModel.updateSessionContext(sessionID: "session-2", sessionState: .ready)

        XCTAssertNil(viewModel.currentPlan)
    }

    func testInitRecoversMissingPersistedSessionAndPersistsReplacementSessionID() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, params, _ in
            switch method {
            case "chat.attach":
                let sessionID = params?["session_id"] as? String
                if sessionID == "persisted-session" {
                    throw TestError.forcedFailure
                }

                return [
                    "channel_id": 611,
                    "acp_session_id": "acp-\(sessionID ?? "new-session")",
                ] as [String: Any]
            case "chat.start":
                return ["session_id": "new-session"] as [String: Any]
            case "chat.history":
                return ["updates": []] as [String: Any]
            default:
                throw TestError.missingStub
            }
        }

        let manager = AgentSessionManager(connectionManager: connection)
        var recoveredSessionID: String?
        let viewModel = ChatSessionViewModel(
            agentSessionManager: manager,
            sessionID: "persisted-session",
            sessionState: .ready,
            threadID: "thread-1",
            selectedAgentName: "opencode",
            availableAgents: [AgentConfig(name: "opencode", command: "opencode acp", cwd: nil)],
            onSessionIDRecovered: { recoveredSessionID = $0 }
        )

        let didRecover = await waitForCondition {
            viewModel.sessionID == "new-session" && viewModel.isInputEnabled
        }

        XCTAssertTrue(didRecover)
        XCTAssertEqual(recoveredSessionID, "new-session")
        XCTAssertTrue(connection.requests.contains(where: { $0.method == "chat.attach" && ($0.params?["session_id"] as? String) == "persisted-session" }))
        XCTAssertTrue(connection.requests.contains(where: { $0.method == "chat.start" }))
        XCTAssertTrue(connection.requests.contains(where: { $0.method == "chat.attach" && ($0.params?["session_id"] as? String) == "new-session" }))
    }

    func testSecondPromptReceivesResponseAfterFirstCompletes() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let channelID: UInt16 = 77
        connection.requestHandler = { method, params, _ in
            switch method {
            case "chat.start":
                return ["session_id": "session-1"] as [String: Any]
            case "chat.attach":
                return [
                    "channel_id": Int(channelID),
                    "acp_session_id": "acp-session-1",
                ] as [String: Any]
            case "chat.history":
                return ["updates": []] as [String: Any]
            default:
                throw TestError.missingStub
            }
        }

        let manager = AgentSessionManager(connectionManager: connection)
        let sessionID = try await manager.startSession(
            agentConfig: AgentConfig(name: "opencode", command: "opencode acp", cwd: nil),
            threadID: "thread-1"
        )

        let viewModel = ChatSessionViewModel(
            agentSessionManager: manager,
            sessionID: sessionID,
            sessionState: .ready,
            threadID: "thread-1",
            selectedAgentName: "opencode",
            availableAgents: [AgentConfig(name: "opencode", command: "opencode acp", cwd: nil)]
        )

        let didHydrate = await waitForCondition { viewModel.isHydrated }
        XCTAssertTrue(didHydrate, "VM should hydrate")
        XCTAssertTrue(viewModel.isInputEnabled, "Input should be enabled before first prompt")

        // --- First prompt: simulate realistic streaming ---
        let prompt1 = Task { await viewModel.sendPrompt(text: "hello") }

        let didSend1 = await waitForCondition { connection.sentBinaryFrames.count >= 1 }
        XCTAssertTrue(didSend1, "First prompt frame should be sent")
        XCTAssertTrue(viewModel.isStreaming, "Should be streaming after first prompt sent")

        // Simulate agent streaming chunks BEFORE the prompt response (like real agent)
        let chunk1 = SessionUpdateNotification(
            sessionId: SessionId("acp-session-1"),
            update: .agentMessageChunk(.text(TextContent(text: "Hello! ")))
        )
        let chunk2 = SessionUpdateNotification(
            sessionId: SessionId("acp-session-1"),
            update: .agentMessageChunk(.text(TextContent(text: "How can I help?")))
        )
        let notif1 = try makeNotificationFrame(channelID: channelID, method: "session/update", params: chunk1)
        manager.handleBinaryFrame(notif1)
        try await Task.sleep(for: .milliseconds(60))

        let notif2 = try makeNotificationFrame(channelID: channelID, method: "session/update", params: chunk2)
        manager.handleBinaryFrame(notif2)
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(viewModel.isStreaming, "Should still be streaming during chunks")

        // Now send the prompt response (agent done)
        let frame1 = connection.sentBinaryFrames[0]
        let request1 = try decodeRequest(from: frame1)
        let response1 = try makeResponseFrame(channelID: channelID, requestID: request1.id, result: SessionPromptResponse(stopReason: .endTurn))
        manager.handleBinaryFrame(response1)

        await prompt1.value

        // Let flush timers settle
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(viewModel.isStreaming, "Should NOT be streaming after first prompt completes")
        XCTAssertTrue(viewModel.isInputEnabled, "Input should be re-enabled after first prompt")
        XCTAssertFalse(viewModel.timelineItems.isEmpty, "Should have timeline items from streaming")

        // Simulate what ChatModeContent.body does on every re-render
        viewModel.updateSessionContext(sessionID: sessionID, sessionState: .ready)
        XCTAssertTrue(viewModel.isInputEnabled, "Input should still be enabled after updateSessionContext")

        // --- Second prompt: same realistic flow ---
        let prompt2 = Task { await viewModel.sendPrompt(text: "thanks") }

        let didSend2 = await waitForCondition { connection.sentBinaryFrames.count >= 2 }
        XCTAssertTrue(didSend2, "Second prompt frame should be sent — got \(connection.sentBinaryFrames.count)")

        // Stream more chunks
        let chunk3 = SessionUpdateNotification(
            sessionId: SessionId("acp-session-1"),
            update: .agentMessageChunk(.text(TextContent(text: "You're welcome!")))
        )
        let notif3 = try makeNotificationFrame(channelID: channelID, method: "session/update", params: chunk3)
        manager.handleBinaryFrame(notif3)
        try await Task.sleep(for: .milliseconds(60))

        // Send prompt response
        let frame2 = connection.sentBinaryFrames[1]
        let request2 = try decodeRequest(from: frame2)
        let response2 = try makeResponseFrame(channelID: channelID, requestID: request2.id, result: SessionPromptResponse(stopReason: .endTurn))
        manager.handleBinaryFrame(response2)

        await prompt2.value

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(viewModel.isStreaming, "Should NOT be streaming after second prompt completes")
        XCTAssertTrue(viewModel.isInputEnabled, "Input should be re-enabled after second prompt")
    }

    // MARK: - Helpers

    private func makeResponseFrame<ResultPayload: Encodable>(
        channelID: UInt16,
        requestID: RequestId,
        result: ResultPayload
    ) throws -> Data {
        let response = JSONRPCResponse(
            id: requestID,
            result: try anyCodable(from: result),
            error: nil
        )
        var payload = try JSONEncoder().encode(response)
        payload.append(0x0A)
        return makeFrame(channelID: channelID, payload: Array(payload))
    }

    private func anyCodable<Payload: Encodable>(from payload: Payload) throws -> AnyCodable {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private func makeNotificationFrame<Params: Encodable>(channelID: UInt16, method: String, params: Params) throws -> Data {
        let payload = JSONRPCNotification(method: method, params: try anyCodable(from: params))
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return makeFrame(channelID: channelID, payload: Array(data))
    }

    private func decodeRequest(from frame: Data) throws -> JSONRPCRequest {
        let payload = frame.dropFirst(2).dropLast()
        return try JSONDecoder().decode(JSONRPCRequest.self, from: payload)
    }

    private static func makeHistoryPayload(
        updates: [SessionUpdateNotification],
        nextCursor: UInt64?
    ) throws -> [String: Any] {
        let updatesData = try JSONEncoder().encode(updates)
        let updatesObject = try XCTUnwrap(JSONSerialization.jsonObject(with: updatesData) as? [Any])

        var payload: [String: Any] = [
            "updates": updatesObject,
        ]
        if let nextCursor {
            payload["next_cursor"] = nextCursor
        }
        return payload
    }
}
