import XCTest
@testable import Threadmill

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
            chatTitle: { _, _ in "" },
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
}
