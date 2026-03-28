import ACPModel
import os
import SwiftUI

struct ChatModeContent: View {
    @Environment(AppState.self) private var appState
    @State private var viewModelCache = ChatSessionViewModelCache()
    @State private var channelByConversationID: [String: UInt16] = [:]

    let thread: ThreadModel
    let chatHarnesses: [ChatHarness]
    let onCreateConversationWithHarness: (ChatHarness) -> Void
    let selectedConversationID: String?
    let reloadToken: Int
    let onConversationStateChange: ([ChatConversation], ChatConversation?) -> Void

    var body: some View {
        if let chatConversationService = appState.chatConversationService {
            let selectedConversation = selectedConversation
            let selectedChannelID = selectedConversation.flatMap { channelByConversationID[$0.id] }
            let reconnectEpoch = appState.agentSessionManager?.reconnectEpoch ?? 0
            let connectionReady = appState.connectionStatus.isConnected
            let capabilities = selectedConversation?.agentSessionID.flatMap { appState.chatCapabilitiesBySessionID[$0] }
                ?? ChatSessionCapabilities()
            let sessionState = resolveSessionState(for: selectedConversation)
            let selectedProjectAgents = appState.selectedProject?.agents ?? []
            let availableAgents = selectedProjectAgents.isEmpty
                ? [AgentConfig(name: "opencode", command: "opencode", cwd: nil)]
                : selectedProjectAgents
            let viewModel = viewModelCache.resolve(
                conversationID: selectedConversation?.id,
                create: {
                    ChatSessionViewModel(
                        agentSessionManager: appState.agentSessionManager,
                        sessionID: selectedConversation?.agentSessionID,
                        channelID: selectedChannelID,
                        threadID: thread.id,
                        sessionState: sessionState,
                        availableModes: capabilities.modes.map { ModeInfo(id: $0.id, name: $0.title ?? $0.id) },
                        availableModels: capabilities.models.map { ModelInfo(modelId: $0.id, name: $0.title ?? $0.id) },
                        currentModeID: capabilities.currentModeID,
                        currentModelID: capabilities.currentModelID,
                        selectedAgentName: selectedConversation?.agentType ?? availableAgents.first?.name ?? "opencode",
                        availableAgents: availableAgents,
                        historyProvider: { threadID, sessionID, cursor in
                            try await appState.chatHistory(threadID: threadID, sessionID: sessionID, cursor: cursor)
                        }
                    )
                }
            )

            ChatSessionView(viewModel: viewModel)
                .task(id: "\(selectedConversation?.agentSessionID ?? ""):\(selectedChannelID?.description ?? "")") {
                    viewModel.configureSession(sessionID: selectedConversation?.agentSessionID, channelID: selectedChannelID)
                }
                .task(id: sessionStateTaskID(sessionState: sessionState, conversationID: selectedConversation?.id)) {
                    viewModel.updateSessionState(sessionState)
                    viewModel.applyCapabilities(
                        modes: capabilities.modes.map { ModeInfo(id: $0.id, name: $0.title ?? $0.id) },
                        models: capabilities.models.map { ModelInfo(modelId: $0.id, name: $0.title ?? $0.id) },
                        currentModeID: capabilities.currentModeID,
                        currentModelID: capabilities.currentModelID
                    )
                }
                .task(id: reloadToken) {
                    await refreshConversationState(with: chatConversationService)
                }
                .task(id: selectedConversationID) {
                    await refreshConversationState(with: chatConversationService)
                }
                .task(id: attachTaskID(
                    conversation: selectedConversation,
                    reconnectEpoch: reconnectEpoch,
                    connectionReady: connectionReady
                )) {
                    await attachChannelIfNeeded(for: selectedConversation)
                }
                .onChange(of: reconnectEpoch) { _, _ in
                    channelByConversationID = [:]
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
            Logger.chat.info(
                "chat.refresh thread=\(self.thread.id, privacy: .public) conversations=\(sorted.count) selected=\(self.selectedConversationID ?? "nil", privacy: .public)"
            )
            onConversationStateChange(sorted, current)
        } catch {
            Logger.chat.error(
                "chat.refresh failed thread=\(self.thread.id, privacy: .public): \(error)"
            )
            onConversationStateChange([], nil)
        }
    }

    private func attachChannelIfNeeded(for conversation: ChatConversation?) async {
        guard let conversation, channelByConversationID[conversation.id] == nil else {
            return
        }

        guard appState.connectionStatus.isConnected else {
            Logger.chat.info(
                "chat.attach deferred thread=\(self.thread.id, privacy: .public) conversation=\(conversation.id, privacy: .public) reason=connection_not_ready"
            )
            return
        }

        Logger.chat.info(
            "chat.attach begin thread=\(self.thread.id, privacy: .public) conversation=\(conversation.id, privacy: .public) session=\(conversation.agentSessionID ?? "nil", privacy: .public)"
        )

        let resolvedConversation: ChatConversation
        do {
            resolvedConversation = try await ChatModeActions.ensureConversationSession(
                threadID: thread.id,
                conversation: conversation,
                appState: appState
            )
        } catch {
            Logger.chat.error(
                "chat.attach failed to ensure session thread=\(self.thread.id, privacy: .public) conversation=\(conversation.id, privacy: .public): \(error)"
            )
            return
        }

        guard
            let sessionID = resolvedConversation.agentSessionID,
            !sessionID.isEmpty
        else {
            Logger.chat.error(
                "chat.attach aborted thread=\(self.thread.id, privacy: .public) conversation=\(resolvedConversation.id, privacy: .public) reason=missing_session_id"
            )
            return
        }

        let maxRetryAttempts = 5
        for attempt in 1 ... maxRetryAttempts {
            guard !Task.isCancelled, channelByConversationID[resolvedConversation.id] == nil else {
                return
            }

            do {
                let channelID = try await appState.chatAttach(threadID: thread.id, sessionID: sessionID)
                channelByConversationID[resolvedConversation.id] = channelID
                Logger.chat.info(
                    "chat.attach success thread=\(self.thread.id, privacy: .public) conversation=\(resolvedConversation.id, privacy: .public) session=\(sessionID, privacy: .public) channel=\(channelID)"
                )
                return
            } catch {
                guard appState.connectionStatus.isConnected, attempt < maxRetryAttempts else {
                    Logger.chat.error(
                        "chat.attach failed thread=\(self.thread.id, privacy: .public) conversation=\(resolvedConversation.id, privacy: .public) session=\(sessionID, privacy: .public) attempt=\(attempt)/\(maxRetryAttempts): \(error)"
                    )
                    return
                }
                Logger.chat.info(
                    "chat.attach retrying thread=\(self.thread.id, privacy: .public) conversation=\(resolvedConversation.id, privacy: .public) session=\(sessionID, privacy: .public) next_attempt=\(attempt + 1)/\(maxRetryAttempts)"
                )
                let delayNanoseconds = UInt64(200_000_000 * attempt)
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }

    private func attachTaskID(conversation: ChatConversation?, reconnectEpoch: UInt64, connectionReady: Bool) -> String {
        let conversationID = conversation?.id ?? "none"
        let ready = connectionReady ? "connected" : "not-connected"
        return "\(conversationID):\(reconnectEpoch):\(ready)"
    }

    private func resolveSessionState(for conversation: ChatConversation?) -> ChatSessionState {
        if let sessionID = conversation?.agentSessionID,
           let state = appState.chatSessionStateBySessionID[sessionID]
        {
            return state
        }

        let status = conversation?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch status {
        case "ready":
            return .ready
        case "failed":
            return .failed(ChatSessionStateError(message: "Session failed."))
        case "ended":
            return .failed(ChatSessionStateError(message: "Session ended."))
        default:
            return .starting
        }
    }

    private func sessionStateTaskID(sessionState: ChatSessionState, conversationID: String?) -> String {
        let stateID: String
        switch sessionState {
        case .starting:
            stateID = "starting"
        case .ready:
            stateID = "ready"
        case .failed:
            stateID = "failed"
        }
        return "\(conversationID ?? "none"):\(stateID)"
    }
}

@MainActor
final class ChatSessionViewModelCache {
    private var cachedConversationID: String?
    private var cachedViewModel: ChatSessionViewModel?

    func resolve(
        conversationID: String?,
        create: () -> ChatSessionViewModel
    ) -> ChatSessionViewModel {
        if let cachedViewModel, cachedConversationID == conversationID {
            return cachedViewModel
        }

        let viewModel = create()
        cachedConversationID = conversationID
        cachedViewModel = viewModel
        return viewModel
    }
}

@MainActor
enum ChatModeActions {
    static func ensureConversationSession(
        threadID: String,
        conversation: ChatConversation,
        appState: AppState
    ) async throws -> ChatConversation {
        let existingSessionID = conversation.agentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existingSessionID.isEmpty else {
            Logger.chat.info(
                "chat.ensure_session existing thread=\(threadID, privacy: .public) conversation=\(conversation.id, privacy: .public) session=\(existingSessionID, privacy: .public)"
            )
            return conversation
        }

        Logger.chat.info(
            "chat.ensure_session starting thread=\(threadID, privacy: .public) conversation=\(conversation.id, privacy: .public) agent=\(conversation.agentType, privacy: .public)"
        )
        let startResponse = try await appState.chatStart(threadID: threadID, agentName: conversation.agentType)
        let boundConversation = try appState.bindConversation(conversation.id, toChatSessionID: startResponse.sessionID)
        Logger.chat.info(
            "chat.ensure_session started thread=\(threadID, privacy: .public) conversation=\(conversation.id, privacy: .public) session=\(startResponse.sessionID, privacy: .public)"
        )
        return boundConversation
    }

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
