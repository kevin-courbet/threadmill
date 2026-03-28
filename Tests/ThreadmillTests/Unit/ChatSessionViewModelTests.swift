import ACPModel
import XCTest
@testable import Threadmill

@MainActor
final class ChatSessionViewModelTests: XCTestCase {
    func testSessionStateGatesInputUntilReady() {
        let viewModel = ChatSessionViewModel(
            agentSessionManager: nil,
            sessionState: .starting
        )

        XCTAssertFalse(viewModel.isInputEnabled)

        viewModel.updateSessionState(.ready)

        XCTAssertTrue(viewModel.isInputEnabled)
    }

    func testConfigureSessionHydratesPaginatedHistoryBeforeLiveUpdates() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let manager = AgentSessionManager(connectionManager: connection)

        var requestedCursors: [UInt64?] = []
        let historyResponses: [UInt64?: ChatHistoryResponse] = [
            nil: ChatHistoryResponse(
                updates: [
                    SessionUpdateNotification(
                        sessionId: SessionId("session-1"),
                        update: .userMessageChunk(.text(TextContent(text: "Question")))
                    ),
                ],
                nextCursor: 10
            ),
            10: ChatHistoryResponse(
                updates: [
                    SessionUpdateNotification(
                        sessionId: SessionId("session-1"),
                        update: .agentMessageChunk(.text(TextContent(text: "Answer")))
                    ),
                ],
                nextCursor: nil
            ),
        ]

        let viewModel = ChatSessionViewModel(
            agentSessionManager: manager,
            sessionID: "session-1",
            channelID: nil,
            threadID: "thread-1",
            sessionState: .ready,
            historyProvider: { _, _, cursor in
                requestedCursors.append(cursor)
                guard let response = historyResponses[cursor] else {
                    XCTFail("Unexpected cursor: \(String(describing: cursor))")
                    return ChatHistoryResponse(updates: [], nextCursor: nil)
                }
                return response
            }
        )

        viewModel.configureSession(sessionID: "session-1", channelID: 612)

        let hydrated = await waitForCondition {
            viewModel.hasHydratedScrollback && viewModel.timelineItems.count >= 2
        }
        XCTAssertTrue(hydrated)
        XCTAssertEqual(requestedCursors.count, 2)
        XCTAssertNil(requestedCursors[0])
        XCTAssertEqual(requestedCursors[1], 10)

        let duplicateHydratedUpdate = SessionUpdateNotification(
            sessionId: SessionId("session-1"),
            update: .agentMessageChunk(.text(TextContent(text: "Answer")))
        )
        let duplicateLine = try makeNotificationLine(method: "session/update", params: duplicateHydratedUpdate)
        manager.handleBinaryFrame(makeFrame(channelID: 612, payload: Array(duplicateLine)))

        try? await Task.sleep(for: .milliseconds(80))
        let messages = viewModel.timelineItems.compactMap { item -> MessageTimelineItem? in
            if case let .message(message) = item {
                return message
            }
            return nil
        }

        let assistantText = messages
            .filter { $0.role == .assistant }
            .map(\.plainText)
            .joined(separator: "\n")
        XCTAssertEqual(assistantText, "Answer")
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

    private func makeNotificationLine<Params: Encodable>(method: String, params: Params) throws -> Data {
        let payload = JSONRPCNotification(method: method, params: try anyCodable(from: params))
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return data
    }

    private func anyCodable<T: Encodable>(from value: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private func makeFrame(channelID: UInt16, payload: [UInt8]) -> Data {
        Data([UInt8(channelID >> 8), UInt8(channelID & 0xFF)] + payload)
    }
}
