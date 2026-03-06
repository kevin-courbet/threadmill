import XCTest
@testable import Threadmill

final class ThreadSessionTabsProviderSourceTests: XCTestCase {
    func testChatSessionCreationPassesAgentSelection() {
        var requestedAgentIDs: [String?] = []

        let provider = ThreadSessionTabsProvider(
            selectedTab: TabItem.chat.id,
            chatConversations: [],
            selectedChatConversationID: nil,
            terminalSessionIDs: [],
            selectedTerminalSessionID: nil,
            presets: [],
            chatAgents: [
                OCAgent(id: "agent-1", name: "Agent 1"),
                OCAgent(id: "agent-2", name: "Agent 2")
            ],
            chatTitle: { _, _ in "" },
            onSelectChatConversation: { _ in },
            onSelectTerminalSession: { _ in },
            onArchiveChatConversations: { _ in },
            onCloseTerminalSessions: { _ in },
            onCreateChatConversation: { requestedAgentIDs.append($0) },
            onAddDefaultTerminalSession: {},
            onAddTerminalSession: { _ in }
        )

        provider.handleDefaultSessionCreation()
        provider.addMenuItems.forEach { $0.action() }

        XCTAssertEqual(requestedAgentIDs, [nil, "agent-1", "agent-2"])
    }
}
