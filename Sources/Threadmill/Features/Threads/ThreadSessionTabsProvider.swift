import SwiftUI

@MainActor
struct ThreadSessionTabsProvider {
    let selectedTab: String
    let chatConversations: [ChatConversation]
    let selectedChatConversationID: String?
    let terminalSessionIDs: [String]
    let selectedTerminalSessionID: String?
    let presets: [Preset]
    let chatHarnesses: [ChatHarness]
    let chatTitle: @MainActor (ChatConversation, Int, Int) -> String
    let onSelectChatConversation: (String) -> Void
    let onSelectTerminalSession: (String) -> Void
    let onArchiveChatConversations: ([String]) -> Void
    let onCloseTerminalSessions: ([String]) -> Void
    let onCreateChatConversation: (ChatHarness?) -> Void
    let onAddDefaultTerminalSession: () -> Void
    let onAddTerminalSession: (String) -> Void

    var sessionTabs: [SessionTabItem] {
        switch selectedTab {
        case TabItem.chat.id:
            return chatConversations.enumerated().map { index, conversation in
                SessionTabItem(id: conversation.id, title: chatTitle(conversation, index, chatConversations.count), icon: "bubble.left", isClosable: true)
            }
        case TabItem.terminal.id:
            return terminalSessionIDs.map { presetName in
                SessionTabItem(
                    id: presetName,
                    title: presets.first(where: { $0.name == presetName })?.label ?? Preset.displayLabel(for: presetName),
                    icon: "terminal",
                    isClosable: true
                )
            }
        default:
            return []
        }
    }

    var selectedSessionID: String? {
        switch selectedTab {
        case TabItem.chat.id:
            return selectedChatConversationID
        case TabItem.terminal.id:
            return selectedTerminalSessionID
        default:
            return nil
        }
    }

    var addMenuItems: [SessionAddMenuItem] {
        switch selectedTab {
        case TabItem.terminal.id:
            return presets.map { preset in
                SessionAddMenuItem(id: preset.name, title: preset.label) {
                    onAddTerminalSession(preset.name)
                }
            }
        case TabItem.chat.id:
            if chatHarnesses.isEmpty {
                return []
            }
            return chatHarnesses.map { harness in
                SessionAddMenuItem(id: harness.id, title: harness.title) {
                    onCreateChatConversation(harness)
                }
            }
        default:
            return []
        }
    }

    var addButtonHelpText: String {
        switch selectedTab {
        case TabItem.terminal.id:
            return "Start Terminal (click) or choose preset (hold)"
        case TabItem.chat.id:
            return "New coding session (click) or choose harness (hold)"
        default:
            return "Add session"
        }
    }

    var addButtonAccessibilityID: String {
        switch selectedTab {
        case TabItem.terminal.id:
            return "terminal.session.add"
        case TabItem.chat.id:
            return "chat.session.add"
        default:
            return "session.add"
        }
    }

    func handleSessionSelection(_ sessionID: String) {
        switch selectedTab {
        case TabItem.chat.id:
            onSelectChatConversation(sessionID)
        case TabItem.terminal.id:
            onSelectTerminalSession(sessionID)
        default:
            break
        }
    }

    func handleSessionClose(_ sessionID: String) {
        switch selectedTab {
        case TabItem.chat.id:
            onArchiveChatConversations([sessionID])
        case TabItem.terminal.id:
            onCloseTerminalSessions([sessionID])
        default:
            break
        }
    }

    func handleCloseAllLeft(_ sessionID: String) {
        guard let index = sessionTabs.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        closeSessions(Array(sessionTabs[..<index].filter(\.isClosable).map(\.id)))
    }

    func handleCloseAllRight(_ sessionID: String) {
        guard let index = sessionTabs.firstIndex(where: { $0.id == sessionID }), index + 1 < sessionTabs.count else {
            return
        }
        closeSessions(Array(sessionTabs[(index + 1)...].filter(\.isClosable).map(\.id)))
    }

    func handleCloseOthers(_ sessionID: String) {
        closeSessions(sessionTabs.filter { $0.id != sessionID && $0.isClosable }.map(\.id))
    }

    func handleDefaultSessionCreation() {
        switch selectedTab {
        case TabItem.chat.id:
            onCreateChatConversation(nil)
        case TabItem.terminal.id:
            onAddDefaultTerminalSession()
        default:
            break
        }
    }

    func closeSessions(_ ids: [String]) {
        guard !ids.isEmpty else {
            return
        }
        switch selectedTab {
        case TabItem.chat.id:
            onArchiveChatConversations(ids)
        case TabItem.terminal.id:
            onCloseTerminalSessions(ids)
        default:
            break
        }
    }
}

struct ThreadModeSessionTabs: View {
    @Environment(AppState.self) private var appState
    @State private var chatActionErrorMessage: String?

    let thread: ThreadModel
    let selectedTab: String
    @Binding var chatConversations: [ChatConversation]
    @Binding var selectedChatConversationID: String?
    @Binding var terminalSessionIDs: [String]
    @Binding var selectedTerminalSessionID: String?
    @Binding var chatReloadToken: Int
    let chatHarnesses: [ChatHarness]
    let tabStateManager: ThreadTabStateManager
    let isTerminalModeSelected: () -> Bool

    var body: some View {
        let provider = ThreadSessionTabsProvider(
            selectedTab: selectedTab,
            chatConversations: chatConversations,
            selectedChatConversationID: selectedChatConversationID,
            terminalSessionIDs: terminalSessionIDs,
            selectedTerminalSessionID: selectedTerminalSessionID,
            presets: appState.presets,
            chatHarnesses: chatHarnesses,
            chatTitle: ChatModeActions.chatTitle,
            onSelectChatConversation: { selectedChatConversationID = $0 },
            onSelectTerminalSession: { selectedTerminalSessionID = $0 },
            onArchiveChatConversations: { conversationIDs in
                ChatModeActions.archiveChatConversations(
                    conversationIDs,
                    appState: appState,
                    chatConversations: { chatConversations },
                    selectedChatConversationIDBinding: $selectedChatConversationID,
                    chatReloadToken: $chatReloadToken,
                    tabStateManager: tabStateManager,
                    errorMessageBinding: $chatActionErrorMessage
                )
            },
            onCloseTerminalSessions: { sessionIDs in
                TerminalModeActions.closeTerminalSessions(
                    sessionIDs,
                    appState: appState,
                    terminalSessionIDs: $terminalSessionIDs,
                    selectedTerminalSessionIDBinding: $selectedTerminalSessionID,
                    isTerminalModeSelected: isTerminalModeSelected,
                    tabStateManager: tabStateManager
                )
            },
            onCreateChatConversation: {
                ChatModeActions.createChatConversation(
                    thread: thread,
                    appState: appState,
                    selectedChatConversationIDBinding: $selectedChatConversationID,
                    chatReloadToken: $chatReloadToken,
                    tabStateManager: tabStateManager,
                    errorMessageBinding: $chatActionErrorMessage,
                    harness: $0
                )
            },
            onAddDefaultTerminalSession: {
                TerminalModeActions.addDefaultTerminalSession(
                    appState: appState,
                    terminalSessionIDs: $terminalSessionIDs,
                    selectedTerminalSessionIDBinding: $selectedTerminalSessionID,
                    tabStateManager: tabStateManager
                )
            },
            onAddTerminalSession: { preset in
                TerminalModeActions.addTerminalSession(
                    preset: preset,
                    appState: appState,
                    terminalSessionIDs: $terminalSessionIDs,
                    selectedTerminalSessionIDBinding: $selectedTerminalSessionID,
                    tabStateManager: tabStateManager
                )
            }
        )

        SessionTabsScrollView(
            tabs: provider.sessionTabs,
            selectedTabID: provider.selectedSessionID,
            onSelect: provider.handleSessionSelection,
            onClose: provider.handleSessionClose,
            onCloseAllLeft: provider.handleCloseAllLeft,
            onCloseAllRight: provider.handleCloseAllRight,
            onCloseOthers: provider.handleCloseOthers,
            onAddDefault: provider.handleDefaultSessionCreation,
            addMenuItems: provider.addMenuItems,
            addButtonHelp: provider.addButtonHelpText,
            addButtonAccessibilityID: provider.addButtonAccessibilityID
        )
        .alert(
            "Chat Action Failed",
            isPresented: Binding(
                get: { chatActionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        chatActionErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(chatActionErrorMessage ?? "Unknown chat error")
        }
    }
}

struct ThreadModeKeyboardShortcuts: View {
    @Binding var selectedTab: String
    let visibleModeIDs: [String]

    var body: some View {
        Group {
            Button("") { selectModeWithShortcut(index: 1) }.keyboardShortcut("1", modifiers: .command).hidden()
            Button("") { selectModeWithShortcut(index: 2) }.keyboardShortcut("2", modifiers: .command).hidden()
            Button("") { selectModeWithShortcut(index: 3) }.keyboardShortcut("3", modifiers: .command).hidden()
            Button("") { selectModeWithShortcut(index: 4) }.keyboardShortcut("4", modifiers: .command).hidden()
            Button("") { cycleModeForward() }.keyboardShortcut(.tab, modifiers: .control).hidden()
            Button("") { cycleModeBackward() }.keyboardShortcut(.tab, modifiers: [.control, .shift]).hidden()
        }
    }

    private func selectModeWithShortcut(index: Int) {
        guard let modeID = ThreadTabStateManager.modeIDForShortcut(index: index, visibleModeIDs: visibleModeIDs) else {
            return
        }
        selectedTab = modeID
    }

    private func cycleModeForward() {
        guard let nextModeID = ThreadTabStateManager.nextModeID(after: selectedTab, visibleModeIDs: visibleModeIDs) else {
            return
        }
        selectedTab = nextModeID
    }

    private func cycleModeBackward() {
        guard let previousModeID = ThreadTabStateManager.previousModeID(before: selectedTab, visibleModeIDs: visibleModeIDs) else {
            return
        }
        selectedTab = previousModeID
    }
}
