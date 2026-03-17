import XCTest
@testable import Threadmill

@MainActor
final class ThreadSessionTabsProviderSourceTests: XCTestCase {
    func testChatSessionCreationUsesHarnessMenuAndDefaultAction() {
        var requestedHarnesses: [ChatHarness?] = []

        let provider = ThreadSessionTabsProvider(
            selectedTab: TabItem.chat.id,
            chatConversations: [],
            selectedChatConversationID: nil,
            terminalSessionIDs: [],
            selectedTerminalSessionID: nil,
            presets: [],
            chatHarnesses: ChatHarness.allCases,
            chatTitle: { _, _, _ in "" },
            onSelectChatConversation: { _ in },
            onSelectTerminalSession: { _ in },
            onArchiveChatConversations: { _ in },
            onCloseTerminalSessions: { _ in },
            onCreateChatConversation: { requestedHarnesses.append($0) },
            onAddDefaultTerminalSession: {},
            onAddTerminalSession: { _ in }
        )

        provider.handleDefaultSessionCreation()
        provider.addMenuItems.forEach { $0.action() }

        XCTAssertEqual(provider.addButtonHelpText, "New coding session (click) or choose harness (hold)")
        XCTAssertEqual(provider.addMenuItems.map(\.title), ["OpenCode Serve"])
        XCTAssertEqual(requestedHarnesses, [nil, .openCodeServe])
    }

    func testChatSessionTabsLabelNewestUntitledConversationAsNewSession() {
        let older = ChatConversation(
            id: "conv-1",
            threadID: "thread-1",
            opencodeSessionID: "ses-1",
            title: "",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            isArchived: false
        )
        let newer = ChatConversation(
            id: "conv-2",
            threadID: "thread-1",
            opencodeSessionID: "ses-2",
            title: "",
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2),
            isArchived: false
        )

        let provider = ThreadSessionTabsProvider(
            selectedTab: TabItem.chat.id,
            chatConversations: [older, newer],
            selectedChatConversationID: newer.id,
            terminalSessionIDs: [],
            selectedTerminalSessionID: nil,
            presets: [],
            chatHarnesses: ChatHarness.allCases,
            chatTitle: ChatModeActions.chatTitle,
            onSelectChatConversation: { _ in },
            onSelectTerminalSession: { _ in },
            onArchiveChatConversations: { _ in },
            onCloseTerminalSessions: { _ in },
            onCreateChatConversation: { _ in },
            onAddDefaultTerminalSession: {},
            onAddTerminalSession: { _ in }
        )

        XCTAssertEqual(provider.sessionTabs.map(\.title), ["Session 1", "New session"])
    }
}
