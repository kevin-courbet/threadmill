import ACPModel
import Combine
import Foundation
import Observation
import os

@MainActor
@Observable
final class ChatSessionViewModel {
    var timelineItems: [TimelineItem] = []
    var itemIndex: [String: Int] = [:]

    var isStreaming = false
    var currentThought = ""
    var currentMode: String?
    var availableModes: [ModeInfo]
    var currentModelID: String?
    var availableModels: [ModelInfo] = []
    var selectedAgentName: String
    var availableAgents: [AgentConfig]
    var sessionTitle: String?

    var isInputEnabled: Bool {
        !isStreaming && agentSessionManager != nil
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
    private var messageFlushTask: Task<Void, Never>?
    private var pendingToolCallTimelineIDs: Set<String> = []
    private var pendingStreamingRebuild = false
    private var cancellables: Set<AnyCancellable> = []
    private let toolCallFlushSubject = PassthroughSubject<Void, Never>()

    init(
        agentSessionManager: AgentSessionManager?,
        sessionID: String? = nil,
        threadID: String? = nil,
        availableModes: [ModeInfo] = [],
        selectedAgentName: String = "opencode",
        availableAgents: [AgentConfig] = []
    ) {
        self.agentSessionManager = agentSessionManager
        self.sessionID = sessionID
        self.threadID = threadID
        self.availableModes = availableModes
        self.selectedAgentName = selectedAgentName
        self.availableAgents = availableAgents

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

        toolCallFlushSubject
            .throttle(for: .milliseconds(60), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.flushPendingToolCallTimelineUpdates()
            }
            .store(in: &cancellables)
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
        } else if let threadID, let agentSessionManager {
            do {
                sessionID = try await agentSessionManager.startSession(agentConfig: selectedAgent, threadID: threadID)
                if let sessionID {
                    configureSession(from: agentSessionManager, sessionID: sessionID)
                }
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

        guard let sessionID = await ensureSessionReady() else {
            currentMode = modeID
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

        guard let sessionID = await ensureSessionReady() else {
            currentModelID = modelID
            return
        }

        do {
            try await agentSessionManager.setModel(sessionID: sessionID, modelID: modelID)
            currentModelID = modelID
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
            return
        }

        guard let agentSessionManager else {
            return
        }

        guard let sessionID = await ensureSessionReady() else {
            return
        }

        isStreaming = true

        do {
            try await agentSessionManager.sendPrompt(text: trimmed, sessionID: sessionID)
        } catch {
            Logger.chat.error("sendPrompt failed — sessionID=\(sessionID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            finishStreamingCycle(forceRebuild: true)
            return
        }

        finishStreamingCycle(forceRebuild: false)
    }

    func cancelCurrentPrompt() async {
        guard let agentSessionManager else {
            return
        }

        guard let sessionID = await ensureSessionReady() else {
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
            upsertStreamingMessage(role: .user, content: content, messageID: streamingUserMessageID)
        case let .agentMessageChunk(content):
            isStreaming = true
            enqueueAgentChunk(content)
        case let .agentThoughtChunk(content):
            if case let .text(textContent) = content {
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
        case .plan, .availableCommandsUpdate, .usageUpdate:
            break
        }
    }

    func rebuildTimelineWithGrouping(isStreaming: Bool) {
        struct TimelineEvent {
            enum Kind {
                case message(MessageTimelineItem)
                case toolCall(ToolCallTimelineItem)
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

        let events = (messageEvents + toolEvents).sorted { lhs, rhs in
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
        guard var existing = toolCallsByID[update.toolCallId]?.toolCall else {
            return
        }

        if let status = update.status {
            existing.status = status
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

        var timelineItem = toolCallsByID[update.toolCallId] ?? ToolCallTimelineItem(toolCall: existing)
        timelineItem.toolCall = existing
        timelineItem.renderVersion &+= 1
        toolCallsByID[update.toolCallId] = timelineItem
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
        messageFlushTask?.cancel()

        messageFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else {
                return
            }
            self.flushPendingAgentChunks()
            self.messageFlushTask = nil
        }
    }

    private func flushPendingAgentChunks() {
        guard !pendingAgentChunks.isEmpty else {
            return
        }

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

    private func finishStreamingCycle(forceRebuild: Bool) {
        messageFlushTask?.cancel()
        messageFlushTask = nil

        flushPendingAgentChunks()
        flushPendingToolCallTimelineUpdates()

        isStreaming = false
        currentThought = ""
        streamingUserMessageID = UUID().uuidString
        streamingAgentMessageID = UUID().uuidString

        let shouldRebuild = forceRebuild || pendingStreamingRebuild
        pendingStreamingRebuild = false
        if shouldRebuild {
            rebuildTimelineWithGrouping(isStreaming: false)
        }
    }

    private func ensureSessionReady() async -> String? {
        guard let agentSessionManager else {
            return sessionID
        }

        guard let threadID else {
            return sessionID
        }

        if let sessionID, agentSessionManager.hasSession(sessionID: sessionID) {
            return sessionID
        }

        guard let agentConfig = resolvedAgentConfig() else {
            Logger.chat.error("ensureSessionReady — no resolved agent config for \(self.selectedAgentName, privacy: .public)")
            return nil
        }

        do {
            let startedSessionID = try await agentSessionManager.startSession(agentConfig: agentConfig, threadID: threadID)
            sessionID = startedSessionID
            configureSession(from: agentSessionManager, sessionID: startedSessionID)
            return startedSessionID
        } catch {
            Logger.chat.error("ensureSessionReady failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func configureSession(from manager: AgentSessionManager, sessionID: String) {
        applyCapabilities(from: manager, sessionID: sessionID)
        Logger.chat.debug("configureSession — sessionID=\(sessionID, privacy: .public), modes=\(self.availableModes.count, privacy: .public), models=\(self.availableModels.count, privacy: .public)")
    }

    private func consumeSessionUpdate(_ update: SessionUpdateNotification, incomingSessionID: String) {
        handleSessionUpdate(update)
    }

    private func resolvedAgentConfig() -> AgentConfig? {
        if let exact = availableAgents.first(where: { $0.name == selectedAgentName }) {
            return exact
        }
        if let first = availableAgents.first {
            return first
        }
        return nil
    }

    private func applyConfigOptionModels(_ configOptions: [SessionConfigOption]) {
        for option in configOptions {
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
