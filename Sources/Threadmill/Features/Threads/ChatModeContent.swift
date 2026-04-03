import SwiftUI
import os

struct ChatModeContent: View {
    @Environment(AppState.self) private var appState
    @State private var viewModelCache = ChatSessionViewModelCache()

    let thread: ThreadModel
    let chatHarnesses: [ChatHarness]
    let onCreateConversationWithHarness: (ChatHarness) -> Void
    let selectedConversationID: String?
    let reloadToken: Int
    let onConversationStateChange: ([ChatConversation], ChatConversation?) -> Void

    var body: some View {
        if let chatConversationService = appState.chatConversationService {
            let selectedConversation = selectedConversation
            let installedAgents = appState.agentRegistry.filter(\.installed).map(\.toAgentConfig)
            let availableAgents = installedAgents.isEmpty
                ? [AgentConfig(name: "opencode", command: "opencode acp", cwd: nil)]
                : installedAgents
            Group {
                if let selectedConversation {
                    let viewModel = viewModelCache.resolve(
                        conversationID: selectedConversation.id,
                        sessionID: selectedConversation.agentSessionID,
                        create: {
                            Logger.chat.info("ChatModeContent creating ChatSessionViewModel — threadID=\(thread.id, privacy: .public), conversationID=\(selectedConversation.id, privacy: .public), sessionID=\(selectedConversation.agentSessionID ?? "nil", privacy: .public)")
                            return ChatSessionViewModel(
                                agentSessionManager: appState.agentSessionManager,
                                sessionID: selectedConversation.agentSessionID,
                                threadID: thread.id,
                                availableModes: [],
                                selectedAgentName: selectedConversation.agentType,
                                availableAgents: availableAgents
                            )
                        }
                    )

                    ChatSessionView(viewModel: viewModel)
                } else {
                    ChatEmptyStateView(
                        harnesses: chatHarnesses,
                        onCreateConversationWithHarness: { harness in
                            Logger.chat.info("ChatModeContent onCreateConversationWithHarness callback — threadID=\(thread.id, privacy: .public), harness=\(harness.title, privacy: .public), agentType=\(harness.agentType, privacy: .public)")
                            onCreateConversationWithHarness(harness)
                        }
                    )
                }
            }
                .task(id: reloadToken) {
                    await refreshConversationState(with: chatConversationService)
                }
                .task(id: selectedConversationID) {
                    await refreshConversationState(with: chatConversationService)
                }
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

    private var selectedConversation: ChatConversation? {
        selectedConversationID.flatMap { conversationID in
            appState.chatConversationService.flatMap { _ in
                try? appState.databaseManager?.conversation(id: conversationID)
            }
        }
    }

    private func refreshConversationState(with service: any ChatConversationManaging) async {
        do {
            let conversations = try await service.activeConversations(threadID: thread.id)
            let sorted = conversations.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return lhs.createdAt < rhs.createdAt
            }
            let current = sorted.first { $0.id == selectedConversationID }
            onConversationStateChange(sorted, current)
        } catch {
            onConversationStateChange([], nil)
        }
    }
}

private struct ChatEmptyStateView: View {
    let harnesses: [ChatHarness]
    let onCreateConversationWithHarness: (ChatHarness) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No chat sessions")
                .font(.headline)

            Text("Create a session to start chatting in this thread.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let primaryHarness = harnesses.first {
                Button("Start \(primaryHarness.title) Session") {
                    Logger.chat.info("ChatEmptyState CTA tapped — harness=\(primaryHarness.title, privacy: .public), agentType=\(primaryHarness.agentType, privacy: .public)")
                    onCreateConversationWithHarness(primaryHarness)
                }
                .buttonStyle(.borderedProminent)

                if harnesses.count > 1 {
                    ForEach(harnesses.dropFirst()) { harness in
                        Button("Start \(harness.title) Session") {
                            Logger.chat.info("ChatEmptyState CTA tapped — harness=\(harness.title, privacy: .public), agentType=\(harness.agentType, privacy: .public)")
                            onCreateConversationWithHarness(harness)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class ChatSessionViewModelCache {
    private var viewModelsByConversationID: [String: ChatSessionViewModel] = [:]

    func resolve(
        conversationID: String?,
        sessionID: String?,
        create: () -> ChatSessionViewModel
    ) -> ChatSessionViewModel {
        guard let conversationID else {
            return create()
        }

        if let cached = viewModelsByConversationID[conversationID] {
            return cached
        }

        let viewModel = create()
        viewModelsByConversationID[conversationID] = viewModel
        return viewModel
    }

    func remove(conversationID: String) {
        viewModelsByConversationID.removeValue(forKey: conversationID)
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
            chatConversations.wrappedValue = sortConversationsChronologically(conversations)
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

    static func createChatConversation(
        thread: ThreadModel,
        appState: AppState,
        selectedChatConversationIDBinding: Binding<String?>,
        chatReloadToken: Binding<Int>,
        tabStateManager: ThreadTabStateManager,
        errorMessageBinding: Binding<String?> = .constant(nil),
        harness: ChatHarness? = nil
    ) {
        guard let chatConversationService = appState.chatConversationService else {
            errorMessageBinding.wrappedValue = "Chat conversation service unavailable."
            return
        }

        let threadID = thread.id
        let directory = thread.worktreePath

        Task {
            do {
                let selectedHarness = harness ?? .opencode
                let conversation = try await chatConversationService.createConversation(
                    threadID: threadID,
                    agentType: selectedHarness.agentType
                )

                await MainActor.run {
                    errorMessageBinding.wrappedValue = nil
                    selectedChatConversationIDBinding.wrappedValue = conversation.id
                    tabStateManager.setSelectedSessionID(conversation.id, modeID: TabItem.chat.id, threadID: threadID)
                    chatReloadToken.wrappedValue += 1
                }
            } catch {
                await MainActor.run {
                    errorMessageBinding.wrappedValue = error.localizedDescription
                }
            }
        }
    }

    static func archiveChatConversations(
        _ conversationIDs: [String],
        appState: AppState,
        chatConversations: @escaping () -> [ChatConversation],
        selectedChatConversationIDBinding: Binding<String?>,
        chatReloadToken: Binding<Int>,
        tabStateManager: ThreadTabStateManager,
        errorMessageBinding: Binding<String?> = .constant(nil)
    ) {
        guard
            !conversationIDs.isEmpty,
            let thread = appState.selectedThread,
            let chatConversationService = appState.chatConversationService
        else {
            return
        }

        Task {
            do {
                for conversationID in conversationIDs {
                    try await chatConversationService.archiveConversation(id: conversationID)
                }

                await MainActor.run {
                    errorMessageBinding.wrappedValue = nil
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
            } catch {
                await MainActor.run {
                    errorMessageBinding.wrappedValue = error.localizedDescription
                }
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
        chatConversations.wrappedValue = sortConversationsChronologically(chatConversations.wrappedValue)

        // Only trust current if it still exists in the active conversations list.
        // After archiving, the VM may still hold a stale currentConversation reference
        // until loadConversations completes — don't let it override the selection.
        if let current, conversations.contains(where: { $0.id == current.id }) {
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

    static func chatTitle(for conversation: ChatConversation, index: Int, totalCount: Int) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return AgentConfig.displayName(for: conversation.agentType)
    }

    private static func sortConversationsChronologically(_ conversations: [ChatConversation]) -> [ChatConversation] {
        conversations.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id < $1.id
            }
            return $0.createdAt < $1.createdAt
        }
    }
}
