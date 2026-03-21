import ACPModel
import XCTest
@testable import Threadmill

@MainActor
final class TimelineModelTests: XCTestCase {
    func testEmptySessionBuildsEmptyTimeline() {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil)

        viewModel.rebuildTimelineWithGrouping(isStreaming: false)

        XCTAssertTrue(viewModel.timelineItems.isEmpty)
    }

    func testTextOnlyExchangeBuildsTwoMessages() {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil)
        viewModel.userMessages = [makeMessage(id: "user-1", role: .user, text: "Hi", at: 1)]
        viewModel.agentMessages = [makeMessage(id: "assistant-1", role: .assistant, text: "Hello", at: 2)]

        viewModel.rebuildTimelineWithGrouping(isStreaming: false)

        XCTAssertEqual(viewModel.timelineItems.count, 2)
        XCTAssertEqual(viewModel.timelineItems.map(\.id), ["message:user-1", "message:assistant-1"])
    }

    func testSingleToolCallFlushesIntoGroupBeforeAgentMessage() {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil)
        viewModel.userMessages = [makeMessage(id: "user-1", role: .user, text: "Fix", at: 1)]
        viewModel.toolCallsByID = [
            "tool-1": makeToolCall(id: "tool-1", title: "Read file", kind: .read, status: .completed, at: 2)
        ]
        viewModel.agentMessages = [makeMessage(id: "assistant-1", role: .assistant, text: "Done", at: 3)]

        viewModel.rebuildTimelineWithGrouping(isStreaming: false)

        XCTAssertEqual(viewModel.timelineItems.count, 3)
        XCTAssertEqual(viewModel.timelineItems[1].id, "tool-call-group:assistant-1")
        XCTAssertEqual(viewModel.timelineItems[2].id, "message:assistant-1")
    }

    func testConsecutiveExplorationCallsClusterInGroup() {
        let toolCalls = [
            makeToolCall(id: "tool-1", title: "Read file A", kind: .read, status: .completed, at: 1),
            makeToolCall(id: "tool-2", title: "Search for symbol", kind: .search, status: .completed, at: 2),
            makeToolCall(id: "tool-3", title: "Edit file", kind: .edit, status: .completed, at: 3),
        ]

        let group = ToolCallGroup(id: "group-1", toolCalls: toolCalls, isStreaming: true)

        XCTAssertEqual(group.displayItems.count, 2)
        guard case let .exploration(cluster) = group.displayItems[0] else {
            return XCTFail("Expected first display item to be exploration cluster")
        }
        XCTAssertEqual(cluster.toolCalls.count, 2)
        XCTAssertEqual(cluster.summaryText, "Explored 2 files")
    }

    func testNonConsecutiveExplorationCallsDoNotClusterTogether() {
        let toolCalls = [
            makeToolCall(id: "tool-1", title: "Read file A", kind: .read, status: .completed, at: 1),
            makeToolCall(id: "tool-2", title: "Edit file", kind: .edit, status: .completed, at: 2),
            makeToolCall(id: "tool-3", title: "Search symbol", kind: .search, status: .completed, at: 3),
        ]

        let group = ToolCallGroup(id: "group-1", toolCalls: toolCalls, isStreaming: true)

        XCTAssertEqual(group.displayItems.count, 3)
        guard case .toolCall = group.displayItems[0] else {
            return XCTFail("Expected first item to remain a tool call")
        }
        guard case .toolCall = group.displayItems[1] else {
            return XCTFail("Expected second item to remain a tool call")
        }
        guard case .toolCall = group.displayItems[2] else {
            return XCTFail("Expected third item to remain a tool call")
        }
    }

    func testTurnSummaryComputesCountAndDurationAndModifiedFiles() {
        let start = Date(timeIntervalSince1970: 10)
        let end = Date(timeIntervalSince1970: 14)
        let group = ToolCallGroup(
            id: "group-1",
            toolCalls: [
                makeToolCall(
                    id: "tool-1",
                    title: "Edit main.swift",
                    kind: .edit,
                    status: .completed,
                    at: 10,
                    locations: [ToolLocation(path: "Sources/main.swift", line: 12)]
                ),
                makeToolCall(id: "tool-2", title: "Read config", kind: .read, status: .completed, at: 14),
            ],
            isStreaming: false
        )

        let summary = TurnSummary.from(toolCalls: group.toolCalls, startedAt: start, endedAt: end)

        XCTAssertEqual(summary.toolCount, 2)
        XCTAssertEqual(summary.durationSeconds, 4)
        XCTAssertEqual(summary.modifiedFiles, ["Sources/main.swift"])
    }

    func testStreamingTextDeltasUpdateInPlaceViaItemIndex() {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil)
        viewModel.handleSessionUpdate(
            SessionUpdateNotification(
                sessionId: SessionId("session-1"),
                update: .agentMessageChunk(.text(TextContent(text: "Hel")))
            )
        )
        let firstIDs = viewModel.timelineItems.map(\.id)

        viewModel.handleSessionUpdate(
            SessionUpdateNotification(
                sessionId: SessionId("session-1"),
                update: .agentMessageChunk(.text(TextContent(text: "lo")))
            )
        )

        XCTAssertEqual(viewModel.timelineItems.map(\.id), firstIDs)
        XCTAssertEqual(viewModel.itemIndex["message:streaming-agent"], 0)
        guard case let .message(message) = viewModel.timelineItems[0] else {
            return XCTFail("Expected timeline item to be message")
        }
        XCTAssertEqual(message.plainText, "Hello")
    }

    func testMultiTurnConversationEmitsTurnSummaryBeforeNextUserMessage() {
        let viewModel = ChatSessionViewModel(agentSessionManager: nil)
        viewModel.userMessages = [
            makeMessage(id: "user-1", role: .user, text: "Q1", at: 1),
            makeMessage(id: "user-2", role: .user, text: "Q2", at: 5),
        ]
        viewModel.agentMessages = [makeMessage(id: "assistant-1", role: .assistant, text: "A1", at: 4)]
        viewModel.toolCallsByID = [
            "tool-1": makeToolCall(id: "tool-1", title: "Read", kind: .read, status: .completed, at: 2),
            "tool-2": makeToolCall(id: "tool-2", title: "Edit", kind: .edit, status: .completed, at: 3),
        ]

        viewModel.rebuildTimelineWithGrouping(isStreaming: false)

        let ids = viewModel.timelineItems.map(\.id)
        XCTAssertEqual(ids, [
            "message:user-1",
            "tool-call-group:assistant-1",
            "message:assistant-1",
            "turn-summary:user-2",
            "message:user-2",
        ])
    }

    private func makeMessage(id: String, role: MessageTimelineItem.Role, text: String, at seconds: TimeInterval) -> MessageTimelineItem {
        MessageTimelineItem(
            id: id,
            role: role,
            content: [.text(TextContent(text: text))],
            timestamp: Date(timeIntervalSince1970: seconds)
        )
    }

    private func makeToolCall(
        id: String,
        title: String,
        kind: ToolKind,
        status: ToolStatus,
        at seconds: TimeInterval,
        locations: [ToolLocation]? = nil
    ) -> ToolCallTimelineItem {
        ToolCallTimelineItem(
            toolCall: ToolCall(
                toolCallId: id,
                title: title,
                kind: kind,
                status: status,
                content: [],
                locations: locations,
                timestamp: Date(timeIntervalSince1970: seconds)
            )
        )
    }
}
