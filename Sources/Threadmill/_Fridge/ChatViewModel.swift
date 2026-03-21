import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var conversations: [ChatConversation] = []
    var currentConversation: ChatConversation?
    var messages: [OCMessage] = []
    var isGenerating = false
    var streamingParts: [String: OCMessagePart] = [:]

    var lastError: String?

    private let openCodeClient: any OpenCodeManaging
    private let chatConversationService: any ChatConversationManaging
    private var activeThreadID: String?
    private var activeDirectory: String?
    private var eventStreamDirectory: String?
    private var eventStreamTask: Task<Void, Never>?
    private var eventStreamToken = UUID()
    private var messageLoadTask: Task<Void, Never>?
    private var messageLoadToken = UUID()

    struct DebugSnapshot: Codable, Equatable {
        let activeThreadID: String?
        let activeDirectory: String?
        let eventStreamDirectory: String?
        let conversationCount: Int
        let currentConversationID: String?
        let messageCount: Int
        let isGenerating: Bool
        let lastError: String?

        var summary: String {
            [
                "threadID=\(activeThreadID ?? "nil")",
                "directory=\(activeDirectory ?? "nil")",
                "eventStreamDirectory=\(eventStreamDirectory ?? "nil")",
                "conversationCount=\(conversationCount)",
                "currentConversation=\(currentConversationID ?? "nil")",
                "messageCount=\(messageCount)",
                "isGenerating=\(isGenerating)",
                "lastError=\(lastError ?? "nil")",
            ].joined(separator: "\n")
        }
    }

    init(
        openCodeClient: any OpenCodeManaging,
        chatConversationService: any ChatConversationManaging
    ) {
        self.openCodeClient = openCodeClient
        self.chatConversationService = chatConversationService
    }

    @MainActor deinit {
        eventStreamTask?.cancel()
        messageLoadTask?.cancel()
    }

    func loadConversations(threadID: String, directory: String) async {
        if activeThreadID != threadID || activeDirectory != directory {
            conversations = []
            currentConversation = nil
            messages = []
            streamingParts = [:]
            isGenerating = false
            lastError = nil
            messageLoadTask?.cancel()
            messageLoadTask = nil
            messageLoadToken = UUID()
        }

        activeThreadID = threadID
        activeDirectory = directory

        do {
            startEventStreamIfNeeded(directory: directory)

            conversations = try await chatConversationService.activeConversations(threadID: threadID)
            sortConversationsChronologically()

            if conversations.isEmpty {
                currentConversation = nil
                messages = []
                streamingParts = [:]
                isGenerating = false
                return
            }

            if let currentConversation,
               let refreshed = conversations.first(where: { $0.id == currentConversation.id })
            {
                self.currentConversation = refreshed
            } else {
                currentConversation = conversations.first
            }

            if let sessionID = currentConversation?.agentSessionID, !sessionID.isEmpty {
                await loadMessages(sessionID: sessionID, directory: directory)
            } else {
                messages = []
                streamingParts = [:]
                isGenerating = false
            }
        } catch {
            conversations = []
            currentConversation = nil
            messages = []
            streamingParts = [:]
            isGenerating = false
            lastError = error.localizedDescription
        }
    }

    func sendPrompt(text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return
        }
        guard let directory = activeDirectory else {
            return
        }

        guard let sessionID = currentConversation?.agentSessionID, !sessionID.isEmpty else {
            lastError = "Start a coding session before sending a prompt."
            return
        }

        isGenerating = true
        lastError = nil
        startEventStreamIfNeeded(directory: directory)

        do {
            try await openCodeClient.sendPrompt(sessionID: sessionID, prompt: prompt, directory: directory)
        } catch {
            isGenerating = false
            lastError = error.localizedDescription
        }
    }

    func abort() async {
        guard
            let sessionID = currentConversation?.agentSessionID,
            !sessionID.isEmpty,
            let directory = activeDirectory
        else {
            return
        }

        do {
            try await openCodeClient.abort(sessionID: sessionID, directory: directory)
        } catch {
            lastError = error.localizedDescription
        }

        isGenerating = false
    }

    func selectConversation(_ conversation: ChatConversation) async {
        guard let directory = activeDirectory else {
            return
        }

        guard let selected = conversations.first(where: { $0.id == conversation.id }) else {
            return
        }

        currentConversation = selected
        messages = []
        streamingParts = [:]
        isGenerating = false

        if let sessionID = selected.agentSessionID, !sessionID.isEmpty {
            await loadMessages(sessionID: sessionID, directory: directory)
        }
    }

    func createConversation(threadID: String? = nil, directory: String? = nil) async {
        guard
            let resolvedThreadID = threadID ?? activeThreadID,
            let resolvedDirectory = directory ?? activeDirectory
        else {
            return
        }

        activeThreadID = resolvedThreadID
        activeDirectory = resolvedDirectory

        do {
            startEventStreamIfNeeded(directory: resolvedDirectory)
            let newConversation = try await chatConversationService.createConversation(
                threadID: resolvedThreadID,
                directory: resolvedDirectory
            )

            upsertConversation(newConversation)
            currentConversation = newConversation
            messages = []
            streamingParts = [:]
            isGenerating = false

            if let sessionID = newConversation.agentSessionID, !sessionID.isEmpty {
                await loadMessages(sessionID: sessionID, directory: resolvedDirectory)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archiveConversation(_ conversation: ChatConversation) async {
        guard activeThreadID != nil, activeDirectory != nil else {
            return
        }

        do {
            try await chatConversationService.archiveConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }

            let needsReplacementSelection = currentConversation?.id == conversation.id

            if needsReplacementSelection {
                currentConversation = nil
                messages = []
                streamingParts = [:]
                isGenerating = false
            }

            if conversations.isEmpty {
                return
            }

            if needsReplacementSelection, let nextConversation = conversations.first {
                await selectConversation(nextConversation)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadMessages(sessionID: String, directory: String) async {
        messageLoadTask?.cancel()
        let token = UUID()
        messageLoadToken = token

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let loadedMessages = try await self.openCodeClient.getMessages(sessionID: sessionID, directory: directory)
                guard !Task.isCancelled else {
                    return
                }
                guard
                    self.messageLoadToken == token,
                    self.currentConversation?.agentSessionID == sessionID,
                    self.activeDirectory == directory
                else {
                    return
                }
                self.messages = loadedMessages
                self.streamingParts = [:]
            } catch is CancellationError {
                return
            } catch {
                guard
                    self.messageLoadToken == token,
                    self.currentConversation?.agentSessionID == sessionID,
                    self.activeDirectory == directory
                else {
                    return
                }
                self.messages = []
                self.streamingParts = [:]
                self.lastError = error.localizedDescription
            }
        }

        messageLoadTask = task
        await task.value

        if messageLoadToken == token {
            messageLoadTask = nil
        }
    }

    private func startEventStreamIfNeeded(directory: String) {
        if eventStreamDirectory == directory, eventStreamTask != nil {
            return
        }

        eventStreamTask?.cancel()
        eventStreamDirectory = directory
        let token = UUID()
        eventStreamToken = token

        let eventStream = openCodeClient.streamEvents(directory: directory)
        eventStreamTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.eventStreamToken == token {
                    self.eventStreamTask = nil
                }
            }

            for await event in eventStream {
                if Task.isCancelled {
                    return
                }
                guard let self else {
                    return
                }
                await self.handleEvent(event, directory: directory)
            }
        }
    }

    private func handleEvent(_ event: OCEvent, directory: String) async {
        guard activeDirectory == directory else {
            return
        }

        switch event {
        case let .sessionUpdated(session):
            await applyAutoTitleIfNeeded(from: session)

        case let .messageUpdated(message):
            guard message.sessionID == currentConversation?.agentSessionID else {
                return
            }
            upsertMessage(message, preserveExistingParts: true)

            if message.role.caseInsensitiveCompare("assistant") == .orderedSame {
                Task { @MainActor [weak self] in
                    await self?.refreshConversationTitleIfNeeded(sessionID: message.sessionID, directory: directory)
                }
            }

        case let .messagePartUpdated(update):
            applyPartUpdate(update)

        case let .sessionStatus(statusEvent):
            guard statusEvent.sessionID == currentConversation?.agentSessionID else {
                return
            }

            let normalized = statusEvent.status.type.lowercased()
            let stillRunning = normalized == "busy" || normalized == "running"
            isGenerating = stillRunning
            if !stillRunning {
                streamingParts = [:]
            }

        case let .unknown(type, payload):
            if type == "stream.error" {
                lastError = String(data: payload, encoding: .utf8) ?? "Unknown stream error"
                isGenerating = false
            }
        }
    }

    private func applyPartUpdate(_ update: OCMessagePartUpdate) {
        guard let sessionID = currentConversation?.agentSessionID else {
            return
        }

        let partSessionID = update.part.sessionID ?? update.part.raw["sessionID"]?.stringValue
        if let partSessionID, partSessionID != sessionID {
            return
        }

        guard let messageID = update.part.messageID ?? update.part.raw["messageID"]?.stringValue else {
            return
        }

        if let messageIndex = messages.firstIndex(where: { $0.id == messageID }) {
            var parts = messages[messageIndex].parts
            let existingPart = parts.first(where: { $0.id == update.part.id })
            let mergedPart = mergedPart(from: update, existingPart: existingPart)
            streamingParts[mergedPart.id] = mergedPart

            if let partIndex = parts.firstIndex(where: { $0.id == mergedPart.id }) {
                parts[partIndex] = mergedPart
            } else {
                parts.append(mergedPart)
            }

            messages[messageIndex] = messages[messageIndex].with(parts: parts)
            return
        }

        let mergedPart = mergedPart(from: update, existingPart: nil)
        streamingParts[mergedPart.id] = mergedPart
        let placeholderMessage = OCMessage(
            id: messageID,
            sessionID: sessionID,
            role: "assistant",
            parts: [mergedPart]
        )
        messages.append(placeholderMessage)
    }

    private func mergedPart(from update: OCMessagePartUpdate, existingPart: OCMessagePart?) -> OCMessagePart {
        let mergedRaw = (existingPart?.raw ?? [:]).merging(update.part.raw) { _, new in new }
        let mergedText: String?

        if let delta = update.delta {
            if let current = existingPart?.text {
                if let explicitText = update.part.text, !explicitText.isEmpty, explicitText != current {
                    mergedText = explicitText
                } else {
                    mergedText = current + delta
                }
            } else if let explicitText = update.part.text, !explicitText.isEmpty {
                mergedText = explicitText
            } else {
                mergedText = delta
            }
        } else {
            mergedText = update.part.text ?? existingPart?.text
        }

        return OCMessagePart(
            id: update.part.id,
            type: update.part.type,
            sessionID: update.part.sessionID ?? existingPart?.sessionID,
            messageID: update.part.messageID ?? existingPart?.messageID,
            text: mergedText,
            raw: mergedRaw
        )
    }

    private func upsertConversation(_ conversation: ChatConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        sortConversationsChronologically()
    }

    private func upsertMessage(_ message: OCMessage, preserveExistingParts: Bool) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            let parts = preserveExistingParts && message.parts.isEmpty ? messages[index].parts : message.parts
            messages[index] = message.with(parts: parts)
        } else {
            messages.append(message)
        }
    }

    private func refreshConversationTitleIfNeeded(sessionID: String, directory: String) async {
        guard shouldAutoTitleConversation(forSessionID: sessionID) else {
            return
        }

        do {
            let session = try await openCodeClient.getSession(id: sessionID, directory: directory)
            await applyAutoTitleIfNeeded(from: session)
        } catch {
            return
        }
    }

    private func applyAutoTitleIfNeeded(from session: OCSession) async {
        let generatedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generatedTitle.isEmpty else {
            return
        }

        guard let index = conversations.firstIndex(where: { $0.agentSessionID == session.id }) else {
            return
        }

        let currentTitle = conversations[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentTitle.isEmpty else {
            return
        }

        var updatedConversation = conversations[index]
        updatedConversation.updateTitle(generatedTitle)
        conversations[index] = updatedConversation
        sortConversationsChronologically()

        if currentConversation?.id == updatedConversation.id {
            currentConversation = updatedConversation
        }

        do {
            try await chatConversationService.updateTitle(conversationID: updatedConversation.id, title: generatedTitle)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func shouldAutoTitleConversation(forSessionID sessionID: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.agentSessionID == sessionID }) else {
            return false
        }

        return conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sortConversationsChronologically() {
        conversations.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id < $1.id
            }
            return $0.createdAt < $1.createdAt
        }
    }

    var debugSnapshot: DebugSnapshot {
        DebugSnapshot(
            activeThreadID: activeThreadID,
            activeDirectory: activeDirectory,
            eventStreamDirectory: eventStreamDirectory,
            conversationCount: conversations.count,
            currentConversationID: currentConversation?.id,
            messageCount: messages.count,
            isGenerating: isGenerating,
            lastError: lastError
        )
    }
}

private extension OCMessage {
    func with(parts: [OCMessagePart]) -> OCMessage {
        OCMessage(
            id: id,
            sessionID: sessionID,
            role: role,
            parts: parts,
            agent: agent,
            time: time,
            model: model
        )
    }
}
