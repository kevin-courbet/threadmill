import SwiftUI
struct ThreadDetailView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("threadmill.show-chat-tab") private var showChatTab = true
    @AppStorage("threadmill.show-terminal-tab") private var showTerminalTab = true
    @AppStorage("threadmill.show-files-tab") private var showFilesTab = true
    @AppStorage("threadmill.show-browser-tab") private var showBrowserTab = true

    @State private var selectedTab = TabItem.chat.id
    @State private var terminalSessionIDs: [String] = []
    @State private var selectedTerminalSessionID: String?
    @State private var chatConversations: [ChatConversation] = []
    @State private var selectedChatConversationID: String?
    @State private var chatReloadToken = 0
    @State private var chatAgents: [OCAgent] = []
    @State private var tabStateManager = ThreadTabStateManager()
    private var isUITestMode: Bool { ProcessInfo.processInfo.environment["THREADMILL_UI_TEST_MODE"] == "1" }
    private var isMockTerminalEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["THREADMILL_USE_MOCK_TERMINAL"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }

    var body: some View {
        if let thread = appState.selectedThread {
            VStack(spacing: 0) { thread.status == .active ? AnyView(activeModeContent(thread: thread)) : AnyView(InactiveThreadView(thread: thread)) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .navigation) { modePicker }
                    if showsModeSessionTabs {
                        ToolbarItem(placement: .navigation) {
                            ThreadModeSessionTabs(
                                selectedTab: selectedTab,
                                chatConversations: $chatConversations,
                                selectedChatConversationID: $selectedChatConversationID,
                                terminalSessionIDs: $terminalSessionIDs,
                                selectedTerminalSessionID: $selectedTerminalSessionID,
                                chatReloadToken: $chatReloadToken,
                                chatAgents: chatAgents,
                                tabStateManager: tabStateManager,
                                isTerminalModeSelected: { selectedTab == TabItem.terminal.id }
                            )
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Spacer()
                    }
                    ToolbarItem(placement: .automatic) {
                        ConnectionStatusView(status: appState.connectionStatus)
                    }
                    ToolbarItem(placement: .automatic) {
                        SystemStatsBar(status: appState.connectionStatus)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isUITestMode {
                        AutomationControlsView(thread: thread, selectedTab: $selectedTab, terminalSessionIDs: $terminalSessionIDs, selectedTerminalSessionID: $selectedTerminalSessionID) {
                            TerminalModeActions.attachSelectedTerminalIfNeeded(appState: appState, selectedTerminalSessionID: selectedTerminalSessionID)
                        }
                        .padding(8)
                    }
                }
                .background { ThreadModeKeyboardShortcuts(selectedTab: $selectedTab, visibleModeIDs: visibleModeIDs) }
                .task(id: thread.id) { await restoreThreadState(thread) }
                .onChange(of: selectedTab) { _, nextModeID in
                    guard let thread = appState.selectedThread else { return }
                    let modeID = normalizedModeID(nextModeID)
                    if modeID != nextModeID { selectedTab = modeID; return }
                    tabStateManager.setSelectedMode(modeID, threadID: thread.id)
                    if modeID == TabItem.terminal.id { TerminalModeActions.attachSelectedTerminalIfNeeded(appState: appState, selectedTerminalSessionID: selectedTerminalSessionID) }
                    if modeID == TabItem.chat.id, selectedChatConversationID == nil { selectedChatConversationID = chatConversations.first?.id }
                }
                .onChange(of: selectedTerminalSessionID) { _, _ in
                    guard let thread = appState.selectedThread else { return }
                    tabStateManager.setSelectedSessionID(selectedTerminalSessionID, modeID: TabItem.terminal.id, threadID: thread.id)
                    if selectedTab == TabItem.terminal.id { TerminalModeActions.attachSelectedTerminalIfNeeded(appState: appState, selectedTerminalSessionID: selectedTerminalSessionID) }
                }
                .onChange(of: selectedChatConversationID) { _, _ in
                    guard let thread = appState.selectedThread else { return }
                    tabStateManager.setSelectedSessionID(selectedChatConversationID, modeID: TabItem.chat.id, threadID: thread.id)
                }
                .onChange(of: showChatTab) { _, _ in ensureSelectedModeVisible() }
                .onChange(of: showTerminalTab) { _, _ in ensureSelectedModeVisible() }
                .onChange(of: showFilesTab) { _, _ in ensureSelectedModeVisible() }
                .onChange(of: showBrowserTab) { _, _ in ensureSelectedModeVisible() }
        } else {
            EmptyView()
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $selectedTab) {
            ForEach(visibleModeTabs) { tab in
                Label(LocalizedStringKey(tab.localizedKey), systemImage: tab.icon).tag(tab.id)
            }
        }
        .pickerStyle(.segmented)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
    }

    @ViewBuilder
    private func activeModeContent(thread: ThreadModel) -> some View {
        switch selectedTab {
        case TabItem.chat.id:
            ChatModeContent(thread: thread, selectedConversationID: selectedChatConversationID, reloadToken: chatReloadToken) { conversations, current in
                ChatModeActions.handleChatConversationStateUpdate(conversations, current, appState: appState, selectedChatConversationIDBinding: $selectedChatConversationID, chatConversations: $chatConversations, tabStateManager: tabStateManager)
            }
        case TabItem.terminal.id:
            TerminalModeContent(
                terminalSessionIDs: terminalSessionIDs,
                selectedTerminalSessionID: selectedTerminalSessionID,
                isMockTerminalEnabled: isMockTerminalEnabled,
                onAddDefaultTerminalSession: {
                    TerminalModeActions.addDefaultTerminalSession(appState: appState, terminalSessionIDs: $terminalSessionIDs, selectedTerminalSessionIDBinding: $selectedTerminalSessionID, tabStateManager: tabStateManager)
                },
                onAddTerminalSession: { preset in
                    TerminalModeActions.addTerminalSession(preset: preset, appState: appState, terminalSessionIDs: $terminalSessionIDs, selectedTerminalSessionIDBinding: $selectedTerminalSessionID, tabStateManager: tabStateManager)
                }
            )
        case TabItem.files.id:
            if let fileService = appState.fileService {
                FileBrowserView(rootPath: thread.worktreePath, fileService: fileService, connectionStatus: appState.connectionStatus)
                    .id(thread.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("File browser unavailable", systemImage: "folder", description: Text("Connection to spindle is unavailable."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case TabItem.browser.id:
            if let databaseManager = appState.databaseManager {
                BrowserView(thread: thread, databaseManager: databaseManager)
                    .id(thread.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Browser unavailable", systemImage: "globe", description: Text("Database services are not configured."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            EmptyView()
        }
    }
    private var visibleModeTabs: [TabItem] {
        let tabs = TabItem.modeDefaults.filter { tab in
            switch tab.id {
            case TabItem.chat.id: return showChatTab
            case TabItem.terminal.id: return showTerminalTab
            case TabItem.files.id: return showFilesTab
            case TabItem.browser.id: return showBrowserTab
            default: return true
            }
        }
        return tabs.isEmpty ? [TabItem.chat] : tabs
    }
    private var visibleModeIDs: [String] { visibleModeTabs.map(\.id) }
    private var showsModeSessionTabs: Bool { selectedTab == TabItem.chat.id || selectedTab == TabItem.terminal.id }
    private func normalizedModeID(_ modeID: String) -> String { visibleModeIDs.contains(modeID) ? modeID : (visibleModeIDs.first ?? TabItem.chat.id) }
    private func ensureSelectedModeVisible() { let normalized = normalizedModeID(selectedTab); if normalized != selectedTab { selectedTab = normalized } }
    private func restoreThreadState(_ thread: ThreadModel) async {
        let expectedThreadID = thread.id
        selectedTab = normalizedModeID(tabStateManager.selectedMode(threadID: thread.id))

        var persistedTerminalSessions = tabStateManager.terminalSessionIDs(threadID: thread.id)
        let availablePresetNames = Set(appState.presets.map(\.name))
        persistedTerminalSessions = persistedTerminalSessions.filter { availablePresetNames.contains($0) }
        if persistedTerminalSessions.isEmpty, let defaultTerminalPresetName = TerminalModeActions.defaultTerminalPresetName(appState: appState) {
            persistedTerminalSessions = [defaultTerminalPresetName]
        }
        terminalSessionIDs = persistedTerminalSessions
        tabStateManager.setTerminalSessionIDs(persistedTerminalSessions, threadID: thread.id)
        let persistedTerminalSelection = tabStateManager.selectedSessionID(modeID: TabItem.terminal.id, threadID: thread.id)
        selectedTerminalSessionID = (persistedTerminalSelection != nil && terminalSessionIDs.contains(persistedTerminalSelection!)) ? persistedTerminalSelection : terminalSessionIDs.first
        selectedChatConversationID = tabStateManager.selectedSessionID(modeID: TabItem.chat.id, threadID: thread.id)
        await ChatModeActions.refreshChatConversations(for: thread, appState: appState, chatConversations: $chatConversations, selectedChatConversationIDBinding: $selectedChatConversationID, tabStateManager: tabStateManager)
        guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else { return }
        await ChatModeActions.refreshChatAgents(for: thread, appState: appState, chatAgents: $chatAgents)
        guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else { return }
        if selectedTab == TabItem.terminal.id {
            TerminalModeActions.attachSelectedTerminalIfNeeded(appState: appState, selectedTerminalSessionID: selectedTerminalSessionID)
        }
    }
}
