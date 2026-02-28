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

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["THREADMILL_UI_TEST_MODE"] == "1"
    }

    private var isMockTerminalEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["THREADMILL_USE_MOCK_TERMINAL"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }

    var body: some View {
        if let thread = appState.selectedThread {
            VStack(spacing: 0) {
                toolbarRow

                if thread.status == .active {
                    activeModeContent(thread: thread)
                } else {
                    inactiveThreadState(thread: thread)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if isUITestMode {
                    automationControls(thread: thread)
                        .padding(8)
                }
            }
            .background {
                modeKeyboardShortcuts
            }
            .task(id: thread.id) {
                await restoreThreadState(thread)
            }
            .onChange(of: selectedTab) { _, nextModeID in
                guard let thread = appState.selectedThread else {
                    return
                }

                let modeID = normalizedModeID(nextModeID)
                if modeID != nextModeID {
                    selectedTab = modeID
                    return
                }

                tabStateManager.setSelectedMode(modeID, threadID: thread.id)

                if modeID == TabItem.terminal.id {
                    attachSelectedTerminalIfNeeded()
                }

                if modeID == TabItem.chat.id, selectedChatConversationID == nil {
                    selectedChatConversationID = chatConversations.first?.id
                }
            }
            .onChange(of: selectedTerminalSessionID) { _, _ in
                guard let thread = appState.selectedThread else {
                    return
                }
                tabStateManager.setSelectedSessionID(selectedTerminalSessionID, modeID: TabItem.terminal.id, threadID: thread.id)
                if selectedTab == TabItem.terminal.id {
                    attachSelectedTerminalIfNeeded()
                }
            }
            .onChange(of: selectedChatConversationID) { _, _ in
                guard let thread = appState.selectedThread else {
                    return
                }
                tabStateManager.setSelectedSessionID(selectedChatConversationID, modeID: TabItem.chat.id, threadID: thread.id)
            }
            .onChange(of: showChatTab) { _, _ in
                ensureSelectedModeVisible()
            }
            .onChange(of: showTerminalTab) { _, _ in
                ensureSelectedModeVisible()
            }
            .onChange(of: showFilesTab) { _, _ in
                ensureSelectedModeVisible()
            }
            .onChange(of: showBrowserTab) { _, _ in
                ensureSelectedModeVisible()
            }
        } else {
            EmptyView()
        }
    }

    private var toolbarRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $selectedTab) {
                    ForEach(visibleModeTabs) { tab in
                        Label(tab.title, systemImage: tab.icon)
                            .tag(tab.id)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                if showsModeSessionTabs {
                    SessionTabsScrollView(
                        tabs: sessionTabs,
                        selectedTabID: selectedSessionID,
                        onSelect: handleSessionSelection,
                        onClose: handleSessionClose,
                        onCloseAllLeft: handleCloseAllLeft,
                        onCloseAllRight: handleCloseAllRight,
                        onCloseOthers: handleCloseOthers,
                        onAddDefault: handleDefaultSessionCreation,
                        addMenuItems: addMenuItems,
                        addButtonHelp: addButtonHelpText,
                        addButtonAccessibilityID: addButtonAccessibilityID
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func activeModeContent(thread: ThreadModel) -> some View {
        switch selectedTab {
        case TabItem.chat.id:
            if let openCodeClient = appState.openCodeClient,
               let chatConversationService = appState.chatConversationService
            {
                ChatView(
                    threadID: thread.id,
                    directory: thread.worktreePath,
                    openCodeClient: openCodeClient,
                    chatConversationService: chatConversationService,
                    ensureOpenCodeRunning: {
                        try await appState.ensureOpenCodeRunning()
                    },
                    selectedConversationID: selectedChatConversationID,
                    reloadToken: chatReloadToken,
                    showsConversationTabBar: false,
                    onConversationStateChange: handleChatConversationStateUpdate
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Chat unavailable",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("OpenCode services are not configured.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case TabItem.terminal.id:
            terminalModeContent

        case TabItem.files.id:
            if let fileService = appState.fileService {
                FileBrowserView(rootPath: thread.worktreePath, fileService: fileService)
                    .id(thread.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "File browser unavailable",
                    systemImage: "folder",
                    description: Text("Connection to spindle is unavailable.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case TabItem.browser.id:
            if let databaseManager = appState.databaseManager {
                BrowserView(thread: thread, databaseManager: databaseManager)
                    .id(thread.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Browser unavailable",
                    systemImage: "globe",
                    description: Text("Database services are not configured.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var terminalModeContent: some View {
        if terminalSessionIDs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                Text("No terminal sessions")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Button("New Terminal") {
                    addDefaultTerminalSession()
                }
                .buttonStyle(.borderedProminent)

                if appState.presets.count > 1 {
                    VStack(spacing: 4) {
                        Text("Or start a preset")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        ForEach(appState.presets) { preset in
                            Button(preset.label) {
                                addTerminalSession(preset: preset.name)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                ForEach(terminalSessionIDs, id: \.self) { preset in
                    let isSelected = preset == selectedTerminalSessionID
                    terminalSessionView(for: preset)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func terminalSessionView(for preset: String) -> some View {
        if let endpoint = terminalEndpoints[preset] {
            if isMockTerminalEnabled {
                Text("Mock terminal: \(endpoint.preset)")
                    .accessibilityIdentifier("terminal.mock.text")
            } else {
                GhosttyTerminalView(endpoint: endpoint)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(appState.connectionStatus == .disconnected ? "Disconnected" : "Starting terminal...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("terminal.connecting")
        }
    }

    private func inactiveThreadState(thread: ThreadModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: thread.status == .creating ? "hourglass" : "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(thread.status == .creating ? "Creating thread..." : "Thread is \(thread.status.rawValue)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if thread.status == .hidden {
                Button("Reopen") {
                    Task { await appState.reopenThread(threadID: thread.id) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modeKeyboardShortcuts: some View {
        Group {
            Button("") { selectModeWithShortcut(index: 1) }
                .keyboardShortcut("1", modifiers: .command)
                .hidden()

            Button("") { selectModeWithShortcut(index: 2) }
                .keyboardShortcut("2", modifiers: .command)
                .hidden()

            Button("") { selectModeWithShortcut(index: 3) }
                .keyboardShortcut("3", modifiers: .command)
                .hidden()

            Button("") { selectModeWithShortcut(index: 4) }
                .keyboardShortcut("4", modifiers: .command)
                .hidden()

            Button("") { cycleModeForward() }
                .keyboardShortcut(.tab, modifiers: .control)
                .hidden()

            Button("") { cycleModeBackward() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .hidden()
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

    private var visibleModeIDs: [String] {
        visibleModeTabs.map(\.id)
    }

    private var showsModeSessionTabs: Bool {
        selectedTab == TabItem.chat.id || selectedTab == TabItem.terminal.id
    }

    private var sessionTabs: [SessionTabItem] {
        switch selectedTab {
        case TabItem.chat.id:
            return chatConversations.enumerated().map { index, conversation in
                SessionTabItem(
                    id: conversation.id,
                    title: chatTitle(for: conversation, index: index),
                    icon: "bubble.left",
                    isClosable: true
                )
            }

        case TabItem.terminal.id:
            return terminalSessionIDs.map { presetName in
                SessionTabItem(
                    id: presetName,
                    title: appState.presets.first(where: { $0.name == presetName })?.label ?? Preset.displayLabel(for: presetName),
                    icon: "terminal",
                    isClosable: true
                )
            }

        default:
            return []
        }
    }

    private var selectedSessionID: String? {
        switch selectedTab {
        case TabItem.chat.id:
            return selectedChatConversationID
        case TabItem.terminal.id:
            return selectedTerminalSessionID
        default:
            return nil
        }
    }

    private var addMenuItems: [SessionAddMenuItem] {
        switch selectedTab {
        case TabItem.terminal.id:
            return appState.presets.map { preset in
                SessionAddMenuItem(id: preset.name, title: preset.label) {
                    addTerminalSession(preset: preset.name)
                }
            }

        case TabItem.chat.id:
            if chatAgents.isEmpty {
                return []
            }

            return chatAgents.map { agent in
                SessionAddMenuItem(id: agent.id, title: agent.name) {
                    createChatConversation()
                }
            }

        default:
            return []
        }
    }

    private var addButtonHelpText: String {
        switch selectedTab {
        case TabItem.terminal.id:
            return "Start Terminal (click) or choose preset (hold)"
        case TabItem.chat.id:
            return "New conversation (click) or choose agent (hold)"
        default:
            return "Add session"
        }
    }

    private var addButtonAccessibilityID: String {
        switch selectedTab {
        case TabItem.terminal.id:
            return "terminal.session.add"
        case TabItem.chat.id:
            return "chat.session.add"
        default:
            return "session.add"
        }
    }

    private var terminalEndpoints: [String: RelayEndpoint] {
        let terminalTabs = appState.terminalTabs
        return Dictionary(uniqueKeysWithValues: terminalTabs.compactMap { tab in
            guard let presetName = tab.preset?.name, let endpoint = tab.endpoint else {
                return nil
            }
            return (presetName, endpoint)
        })
    }

    private var defaultTerminalPresetName: String? {
        if appState.presets.contains(where: { $0.name == "terminal" }) {
            return "terminal"
        }
        return appState.presets.first?.name
    }

    private func normalizedModeID(_ modeID: String) -> String {
        if visibleModeIDs.contains(modeID) {
            return modeID
        }
        return visibleModeIDs.first ?? TabItem.chat.id
    }

    private func ensureSelectedModeVisible() {
        let normalized = normalizedModeID(selectedTab)
        if normalized != selectedTab {
            selectedTab = normalized
        }
    }

    private func restoreThreadState(_ thread: ThreadModel) async {
        let expectedThreadID = thread.id
        selectedTab = normalizedModeID(tabStateManager.selectedMode(threadID: thread.id))

        var persistedTerminalSessions = tabStateManager.terminalSessionIDs(threadID: thread.id)
        let availablePresetNames = Set(appState.presets.map(\.name))
        persistedTerminalSessions = persistedTerminalSessions.filter { availablePresetNames.contains($0) }
        if persistedTerminalSessions.isEmpty, let defaultTerminalPresetName {
            persistedTerminalSessions = [defaultTerminalPresetName]
        }

        terminalSessionIDs = persistedTerminalSessions
        tabStateManager.setTerminalSessionIDs(persistedTerminalSessions, threadID: thread.id)

        let persistedTerminalSelection = tabStateManager.selectedSessionID(modeID: TabItem.terminal.id, threadID: thread.id)
        if let persistedTerminalSelection, terminalSessionIDs.contains(persistedTerminalSelection) {
            selectedTerminalSessionID = persistedTerminalSelection
        } else {
            selectedTerminalSessionID = terminalSessionIDs.first
        }

        selectedChatConversationID = tabStateManager.selectedSessionID(modeID: TabItem.chat.id, threadID: thread.id)
        await refreshChatConversations(for: thread)
        guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
            return
        }

        await refreshChatAgents(for: thread)
        guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
            return
        }

        if selectedTab == TabItem.terminal.id {
            attachSelectedTerminalIfNeeded()
        }
    }

    private func refreshChatConversations(for thread: ThreadModel) async {
        let expectedThreadID = thread.id

        guard let chatConversationService = appState.chatConversationService else {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatConversations = []
            return
        }

        do {
            let conversations = try await chatConversationService.activeConversations(threadID: thread.id)
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatConversations = conversations
        } catch {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatConversations = []
        }

        guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
            return
        }

        if let selectedChatConversationID,
           chatConversations.contains(where: { $0.id == selectedChatConversationID })
        {
            return
        }

        selectedChatConversationID = chatConversations.first?.id
        tabStateManager.setSelectedSessionID(selectedChatConversationID, modeID: TabItem.chat.id, threadID: thread.id)
    }

    private func refreshChatAgents(for thread: ThreadModel) async {
        let expectedThreadID = thread.id

        guard let openCodeClient = appState.openCodeClient else {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatAgents = []
            return
        }

        do {
            let agents = try await openCodeClient.getAgents(directory: thread.worktreePath)
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatAgents = agents
        } catch {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatAgents = []
        }
    }

    private func handleChatConversationStateUpdate(_ conversations: [ChatConversation], _ current: ChatConversation?) {
        chatConversations = conversations

        if let current {
            selectedChatConversationID = current.id
            guard let thread = appState.selectedThread else {
                return
            }
            tabStateManager.setSelectedSessionID(current.id, modeID: TabItem.chat.id, threadID: thread.id)
            return
        }

        if let selectedChatConversationID,
           conversations.contains(where: { $0.id == selectedChatConversationID })
        {
            return
        }

        selectedChatConversationID = conversations.first?.id
    }

    private func handleSessionSelection(_ sessionID: String) {
        switch selectedTab {
        case TabItem.chat.id:
            selectedChatConversationID = sessionID
        case TabItem.terminal.id:
            selectedTerminalSessionID = sessionID
        default:
            break
        }
    }

    private func handleSessionClose(_ sessionID: String) {
        switch selectedTab {
        case TabItem.chat.id:
            archiveChatConversations([sessionID])
        case TabItem.terminal.id:
            closeTerminalSessions([sessionID])
        default:
            break
        }
    }

    private func handleCloseAllLeft(_ sessionID: String) {
        guard let index = sessionTabs.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        let ids = sessionTabs[..<index]
            .filter(\.isClosable)
            .map(\.id)
        closeSessions(ids)
    }

    private func handleCloseAllRight(_ sessionID: String) {
        guard let index = sessionTabs.firstIndex(where: { $0.id == sessionID }), index + 1 < sessionTabs.count else {
            return
        }

        let ids = sessionTabs[(index + 1)...]
            .filter(\.isClosable)
            .map(\.id)
        closeSessions(ids)
    }

    private func handleCloseOthers(_ sessionID: String) {
        let ids = sessionTabs
            .filter { $0.id != sessionID && $0.isClosable }
            .map(\.id)
        closeSessions(ids)
    }

    private func closeSessions(_ ids: [String]) {
        guard !ids.isEmpty else {
            return
        }

        switch selectedTab {
        case TabItem.chat.id:
            archiveChatConversations(ids)
        case TabItem.terminal.id:
            closeTerminalSessions(ids)
        default:
            break
        }
    }

    private func handleDefaultSessionCreation() {
        switch selectedTab {
        case TabItem.chat.id:
            createChatConversation()
        case TabItem.terminal.id:
            addDefaultTerminalSession()
        default:
            break
        }
    }

    private func addDefaultTerminalSession() {
        guard let preset = defaultTerminalPresetName else {
            return
        }
        addTerminalSession(preset: preset)
    }

    private func addTerminalSession(preset: String) {
        guard appState.presets.contains(where: { $0.name == preset }) else {
            return
        }

        if !terminalSessionIDs.contains(preset) {
            terminalSessionIDs.append(preset)
        }
        selectedTerminalSessionID = preset

        guard let thread = appState.selectedThread else {
            return
        }
        let threadID = thread.id
        tabStateManager.setTerminalSessionIDs(terminalSessionIDs, threadID: threadID)

        Task {
            await appState.startPreset(threadID: threadID, preset: preset)
            await MainActor.run {
                attachSelectedTerminalIfNeeded(threadID: threadID)
            }
        }
    }

    private func closeTerminalSessions(_ sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else {
            return
        }

        let idsToClose = Set(sessionIDs)
        terminalSessionIDs.removeAll { idsToClose.contains($0) }
        if let selectedTerminalSessionID, idsToClose.contains(selectedTerminalSessionID) {
            self.selectedTerminalSessionID = terminalSessionIDs.first
        }

        guard let thread = appState.selectedThread else {
            return
        }
        let threadID = thread.id
        tabStateManager.setTerminalSessionIDs(terminalSessionIDs, threadID: threadID)

        Task {
            for sessionID in sessionIDs {
                await appState.stopPreset(threadID: threadID, preset: sessionID)
            }
            await MainActor.run {
                if selectedTab == TabItem.terminal.id {
                    attachSelectedTerminalIfNeeded(threadID: threadID)
                }
            }
        }
    }

    private func createChatConversation() {
        guard
            let thread = appState.selectedThread,
            let chatConversationService = appState.chatConversationService
        else {
            return
        }

        Task {
            do {
                let conversation = try await chatConversationService.createConversation(
                    threadID: thread.id,
                    directory: thread.worktreePath
                )
                await MainActor.run {
                    selectedChatConversationID = conversation.id
                    tabStateManager.setSelectedSessionID(conversation.id, modeID: TabItem.chat.id, threadID: thread.id)
                    chatReloadToken += 1
                }
            } catch {
                return
            }
        }
    }

    private func archiveChatConversations(_ conversationIDs: [String]) {
        guard
            !conversationIDs.isEmpty,
            let thread = appState.selectedThread,
            let chatConversationService = appState.chatConversationService
        else {
            return
        }

        Task {
            for conversationID in conversationIDs {
                try? await chatConversationService.archiveConversation(id: conversationID)
            }

            await MainActor.run {
                if let selectedChatConversationID, conversationIDs.contains(selectedChatConversationID) {
                    self.selectedChatConversationID = chatConversations
                        .first(where: { !conversationIDs.contains($0.id) })?
                        .id
                }
                tabStateManager.setSelectedSessionID(self.selectedChatConversationID, modeID: TabItem.chat.id, threadID: thread.id)
                chatReloadToken += 1
            }
        }
    }

    private func attachSelectedTerminalIfNeeded(threadID: String? = nil) {
        guard let selectedTerminalSessionID else {
            return
        }

        guard let threadID = threadID ?? appState.selectedThreadID else {
            return
        }

        Task {
            await appState.attachPreset(threadID: threadID, preset: selectedTerminalSessionID)
        }
    }

    private func chatTitle(for conversation: ChatConversation, index: Int) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        if index == 0 {
            return "New chat"
        }
        return "Chat \(index + 1)"
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

    @ViewBuilder
    private func automationControls(thread: ThreadModel) -> some View {
        VStack(spacing: 2) {
            Button("Automation Open Add Project") {
                Task {
                    try? await appState.addProject(path: "/home/wsl/dev/factorio")
                }
            }
            .accessibilityIdentifier("automation.open-add-project")
            .accessibilityLabel("Automation Open Add Project")

            Button("Automation Open New Thread") {
                Task {
                    guard let projectID = appState.projects.first?.id else {
                        return
                    }
                    try? await appState.createThread(
                        projectID: projectID,
                        name: "ui-e2e-thread",
                        sourceType: "new_feature",
                        branch: nil
                    )
                }
            }
            .accessibilityIdentifier("automation.open-new-thread")
            .accessibilityLabel("Automation Open New Thread")

            ForEach(appState.threads) { candidate in
                Button("Automation Switch \(candidate.id)") {
                    appState.selectedThreadID = candidate.id
                }
                .accessibilityIdentifier("automation.switch-thread.\(candidate.id)")
                .accessibilityLabel("Automation Switch \(candidate.id)")
            }

            Button("Automation Close Selected") {
                Task {
                    await appState.closeThread(threadID: thread.id)
                }
            }
            .accessibilityIdentifier("automation.close-selected-thread")
            .accessibilityLabel("Automation Close Selected")

            ForEach(appState.presets, id: \.name) { preset in
                Button("Automation Preset \(preset.name)") {
                    selectedTab = TabItem.terminal.id
                    if !terminalSessionIDs.contains(preset.name) {
                        terminalSessionIDs.append(preset.name)
                    }
                    selectedTerminalSessionID = preset.name
                    attachSelectedTerminalIfNeeded()
                }
                .accessibilityIdentifier("automation.select-preset.\(preset.name)")
                .accessibilityLabel("Automation Preset \(preset.name)")
            }
        }
        .font(.caption2)
    }
}
