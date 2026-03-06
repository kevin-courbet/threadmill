import SwiftUI

struct ChatModeContent: View {
    @Environment(AppState.self) private var appState

    let thread: ThreadModel
    let selectedConversationID: String?
    let reloadToken: Int
    let onConversationStateChange: ([ChatConversation], ChatConversation?) -> Void

    var body: some View {
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
                selectedConversationID: selectedConversationID,
                reloadToken: reloadToken,
                showsConversationTabBar: false,
                onConversationStateChange: onConversationStateChange
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
    }
}

@MainActor
enum ChatModeActions {
    static func refreshChatConversations(
        for thread: ThreadModel,
        appState: AppState,
        chatConversations: Binding<[ChatConversation]>,
        selectedChatConversationIDBinding: Binding<String?>,
        tabStateManager: ThreadTabStateManager
    ) async {
        let expectedThreadID = thread.id

        guard let chatConversationService = appState.chatConversationService else {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatConversations.wrappedValue = []
            return
        }

        do {
            let conversations = try await chatConversationService.activeConversations(threadID: thread.id)
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatConversations.wrappedValue = conversations
        } catch {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatConversations.wrappedValue = []
        }

        guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
            return
        }

        if let selectedChatConversationID = selectedChatConversationIDBinding.wrappedValue,
           chatConversations.wrappedValue.contains(where: { $0.id == selectedChatConversationID })
        {
            return
        }

        selectedChatConversationIDBinding.wrappedValue = chatConversations.wrappedValue.first?.id
        tabStateManager.setSelectedSessionID(selectedChatConversationIDBinding.wrappedValue, modeID: TabItem.chat.id, threadID: thread.id)
    }

    static func refreshChatAgents(
        for thread: ThreadModel,
        appState: AppState,
        chatAgents: Binding<[OCAgent]>
    ) async {
        let expectedThreadID = thread.id

        guard let openCodeClient = appState.openCodeClient else {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatAgents.wrappedValue = []
            return
        }

        do {
            let agents = try await openCodeClient.getAgents(directory: thread.worktreePath)
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatAgents.wrappedValue = agents
        } catch {
            guard !Task.isCancelled, appState.selectedThread?.id == expectedThreadID else {
                return
            }
            chatAgents.wrappedValue = []
        }
    }

    static func createChatConversation(
        appState: AppState,
        selectedChatConversationIDBinding: Binding<String?>,
        chatReloadToken: Binding<Int>,
        tabStateManager: ThreadTabStateManager,
        agentID: String? = nil
    ) {
        guard
            let thread = appState.selectedThread,
            let chatConversationService = appState.chatConversationService
        else {
            return
        }

        Task {
            do {
                let selectedModel = ChatModelSelectionStore.selectedModel(threadID: thread.id)
                let conversation = try await chatConversationService.createConversation(
                    threadID: thread.id,
                    directory: thread.worktreePath,
                    agentID: agentID,
                    model: selectedModel
                )
                await MainActor.run {
                    selectedChatConversationIDBinding.wrappedValue = conversation.id
                    tabStateManager.setSelectedSessionID(conversation.id, modeID: TabItem.chat.id, threadID: thread.id)
                    chatReloadToken.wrappedValue += 1
                }
            } catch {
                return
            }
        }
    }

    static func archiveChatConversations(
        _ conversationIDs: [String],
        appState: AppState,
        chatConversations: @escaping () -> [ChatConversation],
        selectedChatConversationIDBinding: Binding<String?>,
        chatReloadToken: Binding<Int>,
        tabStateManager: ThreadTabStateManager
    ) {
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
                if let selectedChatConversationID = selectedChatConversationIDBinding.wrappedValue,
                   conversationIDs.contains(selectedChatConversationID)
                {
                    selectedChatConversationIDBinding.wrappedValue = chatConversations()
                        .first(where: { !conversationIDs.contains($0.id) })?
                        .id
                }
                tabStateManager.setSelectedSessionID(selectedChatConversationIDBinding.wrappedValue, modeID: TabItem.chat.id, threadID: thread.id)
                chatReloadToken.wrappedValue += 1
            }
        }
    }

    static func handleChatConversationStateUpdate(
        _ conversations: [ChatConversation],
        _ current: ChatConversation?,
        appState: AppState,
        selectedChatConversationIDBinding: Binding<String?>,
        chatConversations: Binding<[ChatConversation]>,
        tabStateManager: ThreadTabStateManager
    ) {
        chatConversations.wrappedValue = conversations

        if let current {
            selectedChatConversationIDBinding.wrappedValue = current.id
            guard let thread = appState.selectedThread else {
                return
            }
            tabStateManager.setSelectedSessionID(current.id, modeID: TabItem.chat.id, threadID: thread.id)
            return
        }

        if let selectedChatConversationID = selectedChatConversationIDBinding.wrappedValue,
           conversations.contains(where: { $0.id == selectedChatConversationID })
        {
            return
        }

        selectedChatConversationIDBinding.wrappedValue = conversations.first?.id
    }

    static func chatTitle(for conversation: ChatConversation, index: Int) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        if index == 0 {
            return "New chat"
        }
        return "Chat \(index + 1)"
    }
}
