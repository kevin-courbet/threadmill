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
