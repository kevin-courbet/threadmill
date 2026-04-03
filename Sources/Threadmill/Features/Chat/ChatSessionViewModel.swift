import ACPModel
import Combine
import Foundation
import Observation
import os

enum ChatSessionState {
    case starting
    case ready
    case failed(any Error)
}

enum ChatSessionStateError: LocalizedError {
    case missingSessionIdentifier

    var errorDescription: String? {
        switch self {
        case .missingSessionIdentifier:
            return "Session is unavailable."
        }
    }
}

@MainActor
@Observable
final class ChatSessionViewModel {
    var timelineItems: [TimelineItem] = []
    var itemIndex: [String: Int] = [:]

    var isStreaming = false
    var currentThought = ""
    var thoughts: [ThoughtTimelineItem] = []
    var currentMode: String?
    var availableModes: [ModeInfo]
    var currentModelID: String?
    var availableModels: [ModelInfo] = []
    var selectedAgentName: String
    var availableAgents: [AgentConfig]
    var sessionTitle: String?
    var sessionState: ChatSessionState
    private(set) var isHydrated = false

    // Config options surfaced to the composer meta bar
    var configOptions: [SessionConfigOption] = []
    var configOptionValues: [String: String] = [:]

    // Context window usage from ACP UsageUpdate events
    var contextUsedTokens: Int = 0
    var contextWindowSize: Int = 0
    var currentPlan: Plan?

    // Turn timer — set when streaming starts, cleared when it ends
    var turnStartedAt: Date?

    var isInputEnabled: Bool {
        guard case .ready = sessionState else {
            return false
        }
        return !isStreaming && agentSessionManager != nil && sessionID != nil
    }

    var userMessages: [MessageTimelineItem] = []
    var agentMessages: [MessageTimelineItem] = []
    var toolCallsByID: [String: ToolCallTimelineItem] = [:]

    private let agentSessionManager: AgentSessionManager?
    private(set) var sessionID: String?
    private let threadID: String?
    private var streamingUserMessageID = UUID().uuidString
    private var streamingAgentMessageID = UUID().uuidString
    private var pendingAgentChunks: [ContentBlock] = []
    private var thoughtAccumulator = ""
    private var messageFlushTask: Task<Void, Never>?
    private var lastMessageFlushAt: Date?
    private var pendingToolCallTimelineIDs: Set<String> = []
    private var pendingStreamingRebuild = false
    private var cancellables: Set<AnyCancellable> = []
    private let toolCallFlushSubject = PassthroughSubject<Void, Never>()
    private var isHydrating = false
    private var isRecoveringSession = false
    private var deferredLiveUpdates: [SessionUpdateNotification] = []
    private let onSessionIDRecovered: ((String) -> Void)?

    init(
        agentSessionManager: AgentSessionManager?,
        sessionID: String? = nil,
        sessionState: ChatSessionState = .ready,
        threadID: String? = nil,
        availableModes: [ModeInfo] = [],
        selectedAgentName: String = "opencode",
        availableAgents: [AgentConfig] = [],
        onSessionIDRecovered: ((String) -> Void)? = nil
    ) {
        self.agentSessionManager = agentSessionManager
        self.sessionID = sessionID
        self.sessionState = sessionState
        self.threadID = threadID
        self.availableModes = availableModes
        self.selectedAgentName = selectedAgentName
        self.availableAgents = availableAgents
        self.onSessionIDRecovered = onSessionIDRecovered

        agentSessionManager?.onSessionUpdate = { [weak self] incomingSessionID, update in
            guard let self else {
                return
            }
            if let expectedSessionID = self.sessionID, expectedSessionID != incomingSessionID {
                return
            }
            self.consumeSessionUpdate(update, incomingSessionID: incomingSessionID)
        }

        if let sessionID, let agentSessionManager, agentSessionManager.hasSession(sessionID: sessionID) {
            configureSession(from: agentSessionManager, sessionID: sessionID)
        }

        if shouldRecoverSession {
            Task { [weak self] in
                await self?.recoverSessionIfNeeded()
            }
        }

        if shouldHydrateScrollback {
            Task { [weak self] in
                await self?.hydrateFromScrollback()
            }
        } else {
            isHydrated = true
        }

        toolCallFlushSubject
            .throttle(for: .milliseconds(60), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.flushPendingToolCallTimelineUpdates()
            }
            .store(in: &cancellables)
    }

    func updateSessionContext(sessionID: String?, sessionState: ChatSessionState) {
        let didChangeSessionID = self.sessionID != sessionID
        guard didChangeSessionID || !sessionStateMatches(self.sessionState, sessionState) else {
            return
        }
        self.sessionState = sessionState

        if didChangeSessionID {
            resetTimelineStateForSessionChange()
            isHydrated = false
        }

        self.sessionID = sessionID

        if let sessionID, let manager = agentSessionManager, manager.hasSession(sessionID: sessionID) {
            configureSession(from: manager, sessionID: sessionID)
        }

        if shouldRecoverSession {
            Task { [weak self] in
                await self?.recoverSessionIfNeeded()
            }
        }

        guard shouldHydrateScrollback else {
            return
        }

        Task { [weak self] in
            await self?.hydrateFromScrollback()
        }
    }

    func retrySession() async {
        sessionState = .starting
        await recoverSessionIfNeeded(force: true)
        guard case .ready = sessionState else {
            return
        }
        if shouldHydrateScrollback {
            await hydrateFromScrollback(force: true)
            return
        }
        sessionState = .failed(ChatSessionStateError.missingSessionIdentifier)
    }

    func selectAgent(named name: String) async {
        guard !isStreaming else {
            return
        }

        guard let selectedAgent = availableAgents.first(where: { $0.name == name }) else {
            selectedAgentName = name
            return
        }

        if let sessionID, let agentSessionManager {
            do {
                _ = try await agentSessionManager.switchAgent(sessionID: sessionID, agentConfig: selectedAgent)
                configureSession(from: agentSessionManager, sessionID: sessionID)
            } catch {
                return
            }
        }

        selectedAgentName = name
    }

    func setMode(_ modeID: String) async {
        guard let agentSessionManager else {
            currentMode = modeID
            return
        }

        guard let sessionID = readySessionID else {
            return
        }

        do {
            try await agentSessionManager.setMode(sessionID: sessionID, modeID: modeID)
            currentMode = modeID
        } catch {
            return
        }
    }

    func setModel(_ modelID: String) async {
        guard let agentSessionManager else {
            currentModelID = modelID
            return
        }

        guard let sessionID = readySessionID else {
            return
        }

        do {
            try await agentSessionManager.setModel(sessionID: sessionID, modelID: modelID)
            currentModelID = modelID
        } catch {
            return
        }
    }

    func setConfigOption(key: String, value: String) async {
        configOptionValues[key] = value

        guard let agentSessionManager else {
            return
        }

        guard let sessionID = readySessionID else {
            return
        }

        do {
            try await agentSessionManager.setConfigOption(
                sessionID: sessionID,
                key: key,
                value: .select(SessionConfigValueId(value))
            )
        } catch {
            return
        }
    }

    func cycleModeForward() async {
        guard !availableModes.isEmpty else {
            return
        }

        let orderedIDs = availableModes.map(\.id)
        guard let firstID = orderedIDs.first else {
            return
        }

        let currentID = currentMode ?? firstID
        let nextID: String
        if let currentIndex = orderedIDs.firstIndex(of: currentID) {
            nextID = orderedIDs[(currentIndex + 1) % orderedIDs.count]
        } else {
            nextID = firstID
        }

        await setMode(nextID)
    }

    func sendPrompt(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            Logger.chat.error("sendPrompt — empty text, skipping")
            return
        }

        guard let agentSessionManager else {
            Logger.chat.error("sendPrompt — no agentSessionManager")
            return
        }

        guard let sessionID = readySessionID else {
            Logger.chat.error("sendPrompt — readySessionID is nil (sessionState=\(String(describing: self.sessionState), privacy: .public), sessionID=\(self.sessionID ?? "nil", privacy: .public))")
            return
        }

        Logger.chat.error("sendPrompt — sending, sessionID=\(sessionID, privacy: .public), promptLength=\(trimmed.count, privacy: .public)")

        // Add user message to timeline immediately — agent doesn't echo it back
        upsertStreamingMessage(
            role: .user,
            content: .text(TextContent(text: trimmed)),
            messageID: streamingUserMessageID
        )

        isStreaming = true
        turnStartedAt = Date()

        do {
            try await agentSessionManager.sendPrompt(text: trimmed, sessionID: sessionID)
            Logger.chat.error("sendPrompt — RPC returned OK, sessionID=\(sessionID, privacy: .public)")
        } catch {
            Logger.chat.error("sendPrompt failed — sessionID=\(sessionID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            sessionState = .failed(error)
            finishStreamingCycle(forceRebuild: true)
            return
        }

        finishStreamingCycle(forceRebuild: false)
    }

    func cancelCurrentPrompt() async {
        guard let agentSessionManager else {
            return
        }

        guard let sessionID = readySessionID else {
            return
        }

        do {
            try await agentSessionManager.cancelPrompt(sessionID: sessionID)
        } catch {
            return
        }

        finishStreamingCycle(forceRebuild: true)
    }

    func handleSessionUpdate(_ update: SessionUpdateNotification) {
        switch update.update {
        case let .userMessageChunk(content):
            if shouldSkipEchoedUserChunk(content) {
                break
            }
            upsertStreamingMessage(role: .user, content: content, messageID: streamingUserMessageID)
        case let .agentMessageChunk(content):
            isStreaming = true
            enqueueAgentChunk(content)
        case let .agentThoughtChunk(content):
            if case let .text(textContent) = content {
                thoughtAccumulator += textContent.text
                currentThought = textContent.text
            }
        case let .toolCall(toolCallUpdate):
            upsertToolCall(from: toolCallUpdate)
            if isStreaming {
                pendingStreamingRebuild = true
                upsertToolCallInTimeline(toolCallID: toolCallUpdate.toolCallId)
            } else {
                rebuildTimelineWithGrouping(isStreaming: false)
            }
        case let .toolCallUpdate(toolCallUpdate):
            applyToolCallUpdate(toolCallUpdate)
            pendingToolCallTimelineIDs.insert(toolCallUpdate.toolCallId)
            toolCallFlushSubject.send(())
        case let .currentModeUpdate(modeID):
            currentMode = modeID
        case let .sessionInfoUpdate(info):
            if !info.titleUpdate.isOmitted {
                sessionTitle = info.title
            }
        case let .configOptionUpdate(configOptions):
            applyConfigOptionModels(configOptions)
        case let .usageUpdate(usage):
            contextUsedTokens = usage.used
            contextWindowSize = usage.size
        case let .plan(plan):
            currentPlan = plan
        case .availableCommandsUpdate:
            break
        }
    }

    func rebuildTimelineWithGrouping(isStreaming: Bool) {
        struct TimelineEvent {
            enum Kind {
                case message(MessageTimelineItem)
                case toolCall(ToolCallTimelineItem)
                case thought(ThoughtTimelineItem)
            }

            let timestamp: Date
            let kind: Kind
            let sortID: String
        }

        let messageEvents = (userMessages + agentMessages).map { message in
            TimelineEvent(timestamp: message.timestamp, kind: .message(message), sortID: "m:\(message.id)")
        }
        let toolEvents = toolCallsByID.values.map { toolCall in
            TimelineEvent(timestamp: toolCall.timestamp, kind: .toolCall(toolCall), sortID: "t:\(toolCall.id)")
        }
        let thoughtEvents = thoughts.map { thought in
            TimelineEvent(timestamp: thought.timestamp, kind: .thought(thought), sortID: "h:\(thought.id)")
        }

        let events = (messageEvents + toolEvents + thoughtEvents).sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.sortID < rhs.sortID
            }
            return lhs.timestamp < rhs.timestamp
        }

        var mergedItems: [TimelineItem] = []
        var bufferedToolCalls: [ToolCallTimelineItem] = []
        var currentTurnToolCalls: [ToolCallTimelineItem] = []
        var turnStart: Date?

        func flushBufferedToolCalls(groupID: String) {
            guard !bufferedToolCalls.isEmpty else {
                return
            }
            mergedItems.append(.toolCallGroup(ToolCallGroup(id: groupID, toolCalls: bufferedToolCalls, isStreaming: isStreaming)))
            bufferedToolCalls.removeAll(keepingCapacity: true)
        }

        for event in events {
            switch event.kind {
            case let .toolCall(toolCall):
                bufferedToolCalls.append(toolCall)
                currentTurnToolCalls.append(toolCall)
                if turnStart == nil {
                    turnStart = toolCall.timestamp
                }

            case let .message(message):
                if message.role == .assistant || message.role == .system {
                    flushBufferedToolCalls(groupID: message.id)
                    if turnStart == nil {
                        turnStart = message.timestamp
                    }
                    mergedItems.append(.message(message))
                    continue
                }

                flushBufferedToolCalls(groupID: "before-\(message.id)")
                if !currentTurnToolCalls.isEmpty {
                    let startedAt = turnStart ?? currentTurnToolCalls.map(\.timestamp).min() ?? message.timestamp
                    let endedAt = currentTurnToolCalls.map(\.timestamp).max() ?? message.timestamp
                    let summary = TurnSummary.from(
                        id: message.id,
                        toolCalls: currentTurnToolCalls,
                        startedAt: startedAt,
                        endedAt: endedAt
                    )
                    mergedItems.append(.turnSummary(summary))
                    currentTurnToolCalls.removeAll(keepingCapacity: true)
                    turnStart = nil
                }

                mergedItems.append(.message(message))
            case let .thought(thought):
                flushBufferedToolCalls(groupID: "before-thought-\(thought.id)")
                mergedItems.append(.thought(thought))
            }
        }

        if !bufferedToolCalls.isEmpty {
            let trailingID = isStreaming ? "streaming" : "trailing"
            flushBufferedToolCalls(groupID: trailingID)
        }

        timelineItems = mergedItems
        rebuildItemIndex()
    }

    private func upsertStreamingMessage(role: MessageTimelineItem.Role, content: ContentBlock, messageID: String) {
        upsertStreamingMessage(role: role, contents: [content], messageID: messageID)
    }

    private func upsertStreamingMessage(role: MessageTimelineItem.Role, contents: [ContentBlock], messageID: String) {
        guard !contents.isEmpty else {
            return
        }

        let messageTimestamp = Date()
        var updatedMessage: MessageTimelineItem

        if role == .assistant, let index = agentMessages.firstIndex(where: { $0.id == messageID }) {
            var message = agentMessages[index]
            message.append(contentsOf: contents)
            message.timestamp = messageTimestamp
            agentMessages[index] = message
            updatedMessage = message
        } else if role == .user, let index = userMessages.firstIndex(where: { $0.id == messageID }) {
            var message = userMessages[index]
            message.append(contentsOf: contents)
            message.timestamp = messageTimestamp
            userMessages[index] = message
            updatedMessage = message
        } else {
            let message = MessageTimelineItem(id: messageID, role: role, content: contents, timestamp: messageTimestamp, renderVersion: 1)
            if role == .assistant {
                agentMessages.append(message)
            } else {
                userMessages.append(message)
            }
            updatedMessage = message
        }

        let timelineID = "message:\(messageID)"
        if let existingIndex = itemIndex[timelineID], timelineItems.indices.contains(existingIndex) {
            replaceTimelineItemIfNeeded(at: existingIndex, with: .message(updatedMessage))
            return
        }

        timelineItems.append(.message(updatedMessage))
        rebuildItemIndex()
    }

    private func upsertToolCall(from update: ToolCallUpdate) {
        let id = update.toolCallId
        let existing = toolCallsByID[id]
        let title = update.title ?? existing?.toolCall.title ?? (update.kind?.rawValue.capitalized ?? "Tool")
        let timestamp = existing?.toolCall.timestamp ?? Date()
        let toolCall = ToolCall(
            toolCallId: id,
            title: title,
            kind: update.kind ?? existing?.toolCall.kind,
            status: update.status,
            content: update.content,
            locations: update.locations ?? existing?.toolCall.locations,
            rawInput: update.rawInput ?? existing?.toolCall.rawInput,
            rawOutput: update.rawOutput ?? existing?.toolCall.rawOutput,
            timestamp: timestamp,
            parentToolCallId: existing?.toolCall.parentToolCallId
        )
        var timelineItem = existing ?? ToolCallTimelineItem(toolCall: toolCall)
        timelineItem.toolCall = toolCall
        timelineItem.renderVersion &+= 1
        toolCallsByID[id] = timelineItem
    }

    private func applyToolCallUpdate(_ update: ToolCallUpdateDetails) {
        guard var item = toolCallsByID[update.toolCallId] else {
            return
        }
        var existing = item.toolCall

        if let status = update.status {
            existing.status = status
            if (status == .completed || status == .failed), item.completedAt == nil {
                item.completedAt = Date()
            }
        }
        if let title = update.title {
            existing.title = title
        }
        if let kind = update.kind {
            existing.kind = kind
        }
        if let content = update.content {
            existing.content = content
        }
        if let locations = update.locations {
            existing.locations = locations
        }
        if let rawInput = update.rawInput {
            existing.rawInput = rawInput
        }
        if let rawOutput = update.rawOutput {
            existing.rawOutput = rawOutput
        }

        item.toolCall = existing
        item.renderVersion &+= 1
        toolCallsByID[update.toolCallId] = item
    }

    private func rebuildItemIndex() {
        itemIndex = Dictionary(uniqueKeysWithValues: timelineItems.enumerated().map { index, item in
            (item.stableId, index)
        })
    }

    private func enqueueAgentChunk(_ content: ContentBlock) {
        pendingAgentChunks.append(content)
        scheduleMessageFlush()
    }

    private func scheduleMessageFlush() {
        let flushInterval: TimeInterval = 0.05
        let now = Date()

        if let lastMessageFlushAt {
            let elapsed = now.timeIntervalSince(lastMessageFlushAt)
            if elapsed >= flushInterval {
                flushPendingAgentChunks()
                return
            }

            guard messageFlushTask == nil else {
                return
            }

            let delay = max(flushInterval - elapsed, 0)
            messageFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else {
                    return
                }
                self.flushPendingAgentChunks()
                self.messageFlushTask = nil
            }
            return
        }

        flushPendingAgentChunks()
    }

    private func flushPendingAgentChunks() {
        guard !pendingAgentChunks.isEmpty else {
            return
        }

        lastMessageFlushAt = Date()
        let chunks = pendingAgentChunks
        pendingAgentChunks.removeAll(keepingCapacity: true)
        upsertStreamingMessage(role: .assistant, contents: chunks, messageID: streamingAgentMessageID)
    }

    private func flushPendingToolCallTimelineUpdates() {
        guard !pendingToolCallTimelineIDs.isEmpty else {
            return
        }

        let pendingIDs = pendingToolCallTimelineIDs
        pendingToolCallTimelineIDs.removeAll(keepingCapacity: true)

        if isStreaming {
            pendingStreamingRebuild = true
            for toolCallID in pendingIDs {
                upsertToolCallInTimeline(toolCallID: toolCallID)
            }
            return
        }

        rebuildTimelineWithGrouping(isStreaming: false)
    }

    private func upsertToolCallInTimeline(toolCallID: String) {
        guard let toolCall = toolCallsByID[toolCallID] else {
            return
        }

        let stableID = "tool-call:\(toolCallID)"
        if let existingIndex = itemIndex[stableID], timelineItems.indices.contains(existingIndex) {
            replaceTimelineItemIfNeeded(at: existingIndex, with: .toolCall(toolCall))
            return
        }

        timelineItems.append(.toolCall(toolCall))
        rebuildItemIndex()
    }

    private func replaceTimelineItemIfNeeded(at index: Int, with newItem: TimelineItem) {
        guard timelineItems.indices.contains(index) else {
            return
        }

        let current = timelineItems[index]
        guard !hasEquivalentEnvelope(current, newItem) else {
            return
        }
        timelineItems[index] = newItem
    }

    private func hasEquivalentEnvelope(_ lhs: TimelineItem, _ rhs: TimelineItem) -> Bool {
        struct Envelope: Equatable {
            let id: String
            let contentLength: Int
            let tail: Substring
        }

        func envelope(id: String, content: String) -> Envelope {
            Envelope(id: id, contentLength: content.count, tail: content.suffix(64))
        }

        switch (lhs, rhs) {
        case let (.message(left), .message(right)):
            return envelope(id: left.id, content: left.plainText) == envelope(id: right.id, content: right.plainText)
        case let (.toolCall(left), .toolCall(right)):
            return envelope(id: left.id, content: toolCallEnvelopeText(left.toolCall)) == envelope(id: right.id, content: toolCallEnvelopeText(right.toolCall))
        case let (.thought(left), .thought(right)):
            return envelope(id: left.id, content: left.text) == envelope(id: right.id, content: right.text)
        default:
            return false
        }
    }

    private func toolCallEnvelopeText(_ toolCall: ToolCall) -> String {
        let contentText = toolCall.content.compactMap { content -> String? in
            switch content {
            case let .content(block):
                if case let .text(text) = block {
                    return text.text
                }
                return nil
            case let .diff(diff):
                return [diff.path, diff.oldText ?? "", diff.newText].joined(separator: "\n")
            case let .terminal(terminal):
                return terminal.terminalId
            }
        }
        .joined(separator: "\n")

        return [toolCall.id, contentText, String(describing: toolCall.rawOutput)].joined(separator: "|")
    }

    private func shouldSkipEchoedUserChunk(_ content: ContentBlock) -> Bool {
        guard case let .text(incomingText) = content,
              let existingUserMessage = userMessages.first(where: { $0.id == streamingUserMessageID }),
              !existingUserMessage.plainText.isEmpty
        else {
            return false
        }

        return existingUserMessage.plainText == incomingText.text
    }

    private func finishStreamingCycle(forceRebuild: Bool) {
        messageFlushTask?.cancel()
        messageFlushTask = nil

        flushPendingAgentChunks()
        flushPendingToolCallTimelineUpdates()

        isStreaming = false
        if !thoughtAccumulator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thoughts.append(
                ThoughtTimelineItem(
                    id: UUID().uuidString,
                    text: thoughtAccumulator,
                    timestamp: Date(),
                    renderVersion: 1
                )
            )
        }
        thoughtAccumulator = ""
        currentThought = ""
        turnStartedAt = nil
        streamingUserMessageID = UUID().uuidString
        streamingAgentMessageID = UUID().uuidString

        let shouldRebuild = forceRebuild || pendingStreamingRebuild
        pendingStreamingRebuild = false
        if shouldRebuild {
            rebuildTimelineWithGrouping(isStreaming: false)
        }
    }

    func hydrateFromScrollback(force: Bool = false) async {
        guard shouldHydrateScrollback else {
            isHydrated = true
            return
        }

        if isHydrating {
            return
        }

        if isHydrated, !force {
            return
        }

        guard let sessionID,
              let threadID,
              let agentSessionManager
        else {
            return
        }

        isHydrating = true
        if case .failed = sessionState {
            sessionState = .starting
        }

        defer {
            isHydrating = false
        }

        do {
            var cursor: UInt64?
            repeat {
                let response = try await agentSessionManager.chatHistory(threadID: threadID, sessionID: sessionID, cursor: cursor)
                for update in response.updates {
                    handleSessionUpdate(update)
                }
                cursor = response.nextCursor
            } while cursor != nil

            finishStreamingCycle(forceRebuild: true)
            isHydrated = true
            if case .starting = sessionState {
                sessionState = .ready
            }

            if !deferredLiveUpdates.isEmpty {
                let pending = deferredLiveUpdates
                deferredLiveUpdates.removeAll(keepingCapacity: true)
                for update in pending {
                    handleSessionUpdate(update)
                }
            }
        } catch {
            Logger.chat.error("hydrateFromScrollback failed — sessionID=\(sessionID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            sessionState = .failed(error)
        }
    }

    private func configureSession(from manager: AgentSessionManager, sessionID: String) {
        applyCapabilities(from: manager, sessionID: sessionID)
        Logger.chat.debug("configureSession — sessionID=\(sessionID, privacy: .public), modes=\(self.availableModes.count, privacy: .public), models=\(self.availableModels.count, privacy: .public)")
    }

    private func consumeSessionUpdate(_ update: SessionUpdateNotification, incomingSessionID: String) {
        let hydrated = self.isHydrated
        let hydrating = self.isHydrating
        Logger.chat.error("consumeSessionUpdate — type=\(String(describing: update.update).prefix(60), privacy: .public), incomingID=\(incomingSessionID.prefix(12), privacy: .public), selfID=\(self.sessionID?.prefix(12) ?? "nil", privacy: .public), isHydrated=\(hydrated, privacy: .public), isHydrating=\(hydrating, privacy: .public)")
        if sessionID == nil {
            sessionID = incomingSessionID
        }
        if shouldHydrateScrollback, (!isHydrated || isHydrating) {
            Logger.chat.error("consumeSessionUpdate — DEFERRED (hydrating)")
            deferredLiveUpdates.append(update)
            return
        }
        if case .starting = sessionState {
            sessionState = .ready
        }
        handleSessionUpdate(update)
    }

    private func sessionStateMatches(_ lhs: ChatSessionState, _ rhs: ChatSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.starting, .starting), (.ready, .ready), (.failed, .failed):
            return true
        default:
            return false
        }
    }

    private var shouldHydrateScrollback: Bool {
        guard case .ready = sessionState else {
            return false
        }
        return sessionID != nil && threadID != nil && agentSessionManager != nil
    }

    private var shouldRecoverSession: Bool {
        guard let sessionID, let manager = agentSessionManager, threadID != nil else {
            return false
        }

        if isRecoveringSession {
            return false
        }

        guard case .ready = sessionState else {
            return false
        }

        return !manager.hasSession(sessionID: sessionID)
    }

    private func recoverSessionIfNeeded(force: Bool = false) async {
        guard let manager = agentSessionManager, let threadID else {
            return
        }

        if isRecoveringSession {
            return
        }

        if !force, let sessionID, manager.hasSession(sessionID: sessionID) {
            return
        }

        isRecoveringSession = true
        let previousSessionID = sessionID
        sessionState = .starting

        defer {
            isRecoveringSession = false
        }

        let selectedAgent = availableAgents.first(where: { $0.name == selectedAgentName })
            ?? AgentConfig(name: selectedAgentName, command: "\(selectedAgentName) acp", cwd: nil)

        do {
            let restoredSessionID = try await manager.restoreSession(
                sessionID: sessionID,
                agentConfig: selectedAgent,
                threadID: threadID
            )
            sessionID = restoredSessionID
            configureSession(from: manager, sessionID: restoredSessionID)
            sessionState = .ready

            if previousSessionID != restoredSessionID {
                onSessionIDRecovered?(restoredSessionID)
            }
        } catch {
            let previous = previousSessionID ?? "nil"
            Logger.chat.error("recoverSessionIfNeeded failed — previousSessionID=\(previous, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            sessionState = .failed(error)
        }
    }

    private var readySessionID: String? {
        guard case .ready = sessionState else {
            return nil
        }
        return sessionID
    }

    private func resetTimelineStateForSessionChange() {
        timelineItems.removeAll(keepingCapacity: false)
        itemIndex.removeAll(keepingCapacity: false)
        userMessages.removeAll(keepingCapacity: false)
        agentMessages.removeAll(keepingCapacity: false)
        toolCallsByID.removeAll(keepingCapacity: false)
        thoughts.removeAll(keepingCapacity: false)
        deferredLiveUpdates.removeAll(keepingCapacity: true)
        pendingAgentChunks.removeAll(keepingCapacity: true)
        pendingToolCallTimelineIDs.removeAll(keepingCapacity: true)
        pendingStreamingRebuild = false
        isStreaming = false
        thoughtAccumulator = ""
        currentThought = ""
        currentPlan = nil
        messageFlushTask?.cancel()
        messageFlushTask = nil
        lastMessageFlushAt = nil
        streamingUserMessageID = UUID().uuidString
        streamingAgentMessageID = UUID().uuidString
    }

    private func applyConfigOptionModels(_ configOptions: [SessionConfigOption]) {
        self.configOptions = configOptions

        for option in configOptions {
            if case let .select(select) = option.kind {
                configOptionValues[option.id.value] = select.currentValue.value
            }

            guard option.id.value == "model" else {
                continue
            }
            if case let .select(select) = option.kind {
                let allOptions: [SessionConfigSelectOption]
                switch select.options {
                case let .ungrouped(options):
                    allOptions = options
                case let .grouped(groups):
                    allOptions = groups.flatMap(\.options)
                }
                availableModels = allOptions.map { selectOption in
                    ModelInfo(modelId: selectOption.value.value, name: selectOption.name)
                }
                currentModelID = select.currentValue.value
            }
        }
    }

    private func applyCapabilities(from manager: AgentSessionManager, sessionID: String) {
        let capabilities = manager.capabilities(for: sessionID)
        availableModes = capabilities.availableModes
        if let modeID = capabilities.currentModeID {
            currentMode = modeID
        }
        availableModels = capabilities.availableModels
        if let modelID = capabilities.currentModelID {
            currentModelID = modelID
        }
    }
}
