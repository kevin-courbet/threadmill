import ACPModel
import Foundation
import Observation
import os

enum ChatSessionState {
    case starting
    case ready
    case failed(any Error)
}

struct ChatSessionStateError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
@Observable
final class ChatSessionViewModel {
    typealias ChatHistoryProvider = @MainActor (_ threadID: String, _ sessionID: String, _ cursor: UInt64?) async throws -> ChatHistoryResponse

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
    var sessionState: ChatSessionState

    var isInputEnabled: Bool {
        if case .ready = sessionState {
            return true
        }
        return false
    }

    private(set) var hasHydratedScrollback = false

    var userMessages: [MessageTimelineItem] = []
    var agentMessages: [MessageTimelineItem] = []
    var toolCallsByID: [String: ToolCallTimelineItem] = [:]

    private let agentSessionManager: AgentSessionManager?
    private let historyProvider: ChatHistoryProvider?
    private(set) var sessionID: String?
    private(set) var channelID: UInt16?
    private let threadID: String?
    private let streamingUserMessageID = "streaming-user"
    private let streamingAgentMessageID = "streaming-agent"
    private var pendingAgentChunks: [ContentBlock] = []
    private var messageFlushTask: Task<Void, Never>?
    private var pendingToolCallTimelineIDs: Set<String> = []
    private var toolCallFlushTask: Task<Void, Never>?
    private var pendingStreamingRebuild = false
    private var hydrateTask: Task<Void, Never>?
    private var hydratedSessionID: String?
    private var hydrationHighWaterCursor: UInt64?
    private var hydratedUpdateSignatures: Set<String> = []
    private var hydratedMessageChunkFingerprints: Set<String> = []

    init(
        agentSessionManager: AgentSessionManager?,
        sessionID: String? = nil,
        channelID: UInt16? = nil,
        threadID: String? = nil,
        sessionState: ChatSessionState = .starting,
        availableModes: [ModeInfo] = [],
        availableModels: [ModelInfo] = [],
        currentModeID: String? = nil,
        currentModelID: String? = nil,
        selectedAgentName: String = "opencode",
        availableAgents: [AgentConfig] = [],
        historyProvider: ChatHistoryProvider? = nil
    ) {
        self.agentSessionManager = agentSessionManager
        self.historyProvider = historyProvider
        self.threadID = threadID
        self.sessionState = sessionState
        self.availableModes = []
        self.availableModels = []
        self.selectedAgentName = selectedAgentName
        self.availableAgents = availableAgents

        applyCapabilities(
            modes: availableModes,
            models: availableModels,
            currentModeID: currentModeID,
            currentModelID: currentModelID
        )

        configureSession(sessionID: sessionID, channelID: channelID)
    }

    func selectAgent(named name: String) async {
        guard !isStreaming else {
            return
        }
        selectedAgentName = name
    }

    func updateSessionState(_ state: ChatSessionState) {
        sessionState = state
    }

    func configureCapabilities(modes: [ModeInfo], models: [ModelInfo]) {
        applyCapabilities(modes: modes, models: models, currentModeID: nil, currentModelID: nil)
    }

    func applyCapabilities(
        modes: [ModeInfo],
        models: [ModelInfo],
        currentModeID: String?,
        currentModelID: String?
    ) {
        availableModes = modes
        availableModels = models

        if let currentModeID,
           modes.contains(where: { $0.id == currentModeID })
        {
            currentMode = currentModeID
        } else if let currentMode,
                  !modes.contains(where: { $0.id == currentMode })
        {
            self.currentMode = modes.first?.id
        }

        if let currentModelID,
           models.contains(where: { $0.modelId == currentModelID })
        {
            self.currentModelID = currentModelID
        } else if let currentModelID,
                  !models.contains(where: { $0.modelId == currentModelID })
        {
            self.currentModelID = models.first?.modelId
        } else if let selectedModelID = self.currentModelID,
                  !models.contains(where: { $0.modelId == selectedModelID })
        {
            self.currentModelID = models.first?.modelId
        }
    }

    func configureSession(sessionID: String?, channelID: UInt16?) {
        let previousChannelID = self.channelID
        if let previousChannelID,
           previousChannelID != channelID
        {
            agentSessionManager?.detachChannel(channelID: previousChannelID)
        }

        self.sessionID = sessionID
        self.channelID = agentSessionManager == nil ? nil : channelID
        Logger.chat.info(
            "chat.vm.configure thread=\(self.threadID ?? "nil", privacy: .public) session=\(self.sessionID ?? "nil", privacy: .public) channel=\(self.channelID.map(String.init) ?? "nil", privacy: .public)"
        )

        hydrateTask?.cancel()
        hydrateTask = Task { [weak self] in
            await self?.hydrateAndAttachLiveUpdates(sessionID: sessionID, channelID: channelID)
        }
    }

    func setMode(_ modeID: String) async {
        guard let agentSessionManager else {
            currentMode = modeID
            return
        }

        guard let channelID, let sessionID else {
            currentMode = modeID
            return
        }

        do {
            try await agentSessionManager.setMode(channelID: channelID, sessionID: sessionID, modeID: modeID)
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

        guard let channelID, let sessionID else {
            currentModelID = modelID
            return
        }

        do {
            try await agentSessionManager.setModel(channelID: channelID, sessionID: sessionID, modelID: modelID)
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
            Logger.chat.info("chat.vm.send_prompt ignored reason=empty_prompt")
            return
        }

        guard let agentSessionManager else {
            Logger.chat.error(
                "chat.vm.send_prompt ignored thread=\(self.threadID ?? "nil", privacy: .public) reason=agent_manager_unavailable"
            )
            return
        }

        guard let channelID, let sessionID else {
            Logger.chat.error(
                "chat.vm.send_prompt ignored thread=\(self.threadID ?? "nil", privacy: .public) reason=session_not_attached session=\(self.sessionID ?? "nil", privacy: .public) channel=\(self.channelID.map(String.init) ?? "nil", privacy: .public)"
            )
            return
        }

        Logger.chat.info(
            "chat.vm.send_prompt start thread=\(self.threadID ?? "nil", privacy: .public) session=\(sessionID, privacy: .public) channel=\(channelID)"
        )

        isStreaming = true

        do {
            try await agentSessionManager.sendPrompt(text: trimmed, channelID: channelID, sessionID: sessionID)
        } catch {
            Logger.chat.error(
                "chat.vm.send_prompt failed thread=\(self.threadID ?? "nil", privacy: .public) session=\(sessionID, privacy: .public) channel=\(channelID): \(error)"
            )
            finishStreamingCycle(forceRebuild: true)
            return
        }

        Logger.chat.info(
            "chat.vm.send_prompt submitted thread=\(self.threadID ?? "nil", privacy: .public) session=\(sessionID, privacy: .public) channel=\(channelID)"
        )

        finishStreamingCycle(forceRebuild: false)
    }

    func cancelCurrentPrompt() async {
        guard let agentSessionManager else {
            return
        }

        guard let channelID, let sessionID else {
            return
        }

        do {
            try await agentSessionManager.cancelPrompt(channelID: channelID, sessionID: sessionID)
        } catch {
            return
        }

        finishStreamingCycle(forceRebuild: true)
    }

    private func hydrateAndAttachLiveUpdates(sessionID: String?, channelID: UInt16?) async {
        guard let sessionID else {
            hasHydratedScrollback = false
            hydrationHighWaterCursor = nil
            hydratedUpdateSignatures.removeAll(keepingCapacity: false)
            hydratedMessageChunkFingerprints.removeAll(keepingCapacity: false)
            return
        }

        if hydratedSessionID != sessionID {
            hasHydratedScrollback = false
            hydratedSessionID = nil
            hydrationHighWaterCursor = nil
            hydratedUpdateSignatures.removeAll(keepingCapacity: false)
            hydratedMessageChunkFingerprints.removeAll(keepingCapacity: false)
        }

        if !hasHydratedScrollback,
           let threadID,
           let historyProvider
        {
            var cursor: UInt64?
            do {
                repeat {
                    let response = try await historyProvider(threadID, sessionID, cursor)
                    for update in response.updates {
                        consumeSessionUpdate(update, source: .history)
                    }
                    cursor = response.nextCursor
                    hydrationHighWaterCursor = cursor ?? hydrationHighWaterCursor
                } while cursor != nil
                hasHydratedScrollback = true
                hydratedSessionID = sessionID
            } catch {
                hasHydratedScrollback = false
            }
        }

        guard
            let channelID,
            let agentSessionManager
        else {
            return
        }

        agentSessionManager.attachChannel(channelID: channelID, sessionID: sessionID) { [weak self] update in
            self?.consumeSessionUpdate(update, source: .live)
        }
    }

    private enum SessionUpdateSource {
        case history
        case live
    }

    private func consumeSessionUpdate(_ update: SessionUpdateNotification, source: SessionUpdateSource) {
        let signature = updateSignature(update)

        switch source {
        case .history:
            hydratedUpdateSignatures.insert(signature)
            recordHydratedMessageChunkFingerprint(update)
            handleSessionUpdate(update)
        case .live:
            if hasHydratedScrollback,
               (hydratedUpdateSignatures.contains(signature) || isHydratedMessageChunkDuplicate(update))
            {
                return
            }
            handleSessionUpdate(update)
        }
    }

    private func recordHydratedMessageChunkFingerprint(_ update: SessionUpdateNotification) {
        guard let fingerprint = messageChunkFingerprint(for: update.update) else {
            return
        }
        hydratedMessageChunkFingerprints.insert(fingerprint)
    }

    private func isHydratedMessageChunkDuplicate(_ update: SessionUpdateNotification) -> Bool {
        guard let fingerprint = messageChunkFingerprint(for: update.update) else {
            return false
        }
        return hydratedMessageChunkFingerprints.contains(fingerprint)
    }

    private func messageChunkFingerprint(for update: SessionUpdate) -> String? {
        switch update {
        case let .userMessageChunk(content):
            return "user:\(contentBlockFingerprint(content))"
        case let .agentMessageChunk(content):
            return "assistant:\(contentBlockFingerprint(content))"
        default:
            return nil
        }
    }

    private func contentBlockFingerprint(_ content: ContentBlock) -> String {
        guard let data = try? JSONEncoder().encode(content) else {
            return "unknown"
        }
        return data.base64EncodedString()
    }

    func handleSessionUpdate(_ update: SessionUpdateNotification) {
        switch update.update {
        case let .userMessageChunk(content):
            upsertStreamingMessage(role: .user, content: content, messageID: streamingUserMessageID)
        case let .agentMessageChunk(content):
            isStreaming = true
            enqueueAgentChunk(content)
        case .agentThoughtChunk:
            break
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
            scheduleToolCallFlush()
        case let .currentModeUpdate(modeID):
            currentMode = modeID
        case let .sessionInfoUpdate(info):
            if !info.titleUpdate.isOmitted {
                sessionTitle = info.title
            }
        case .plan, .availableCommandsUpdate, .configOptionUpdate, .usageUpdate:
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
            if hasTrailingDuplicateContent(existing: message.content, appended: contents) {
                return
            }
            message.append(contentsOf: contents)
            message.timestamp = messageTimestamp
            agentMessages[index] = message
            updatedMessage = message
        } else if role == .user, let index = userMessages.firstIndex(where: { $0.id == messageID }) {
            var message = userMessages[index]
            if hasTrailingDuplicateContent(existing: message.content, appended: contents) {
                return
            }
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
        guard messageFlushTask == nil else {
            return
        }

        messageFlushTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else {
                    break
                }

                self.flushPendingAgentChunks()

                if self.pendingAgentChunks.isEmpty {
                    break
                }
            }
            self?.messageFlushTask = nil
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

    private func scheduleToolCallFlush() {
        guard toolCallFlushTask == nil else {
            return
        }

        toolCallFlushTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else {
                    break
                }

                self.flushPendingToolCallTimelineUpdates()

                if self.pendingToolCallTimelineIDs.isEmpty {
                    break
                }
            }
            self?.toolCallFlushTask = nil
        }
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
        guard lhs.stableId == rhs.stableId else {
            return false
        }

        func envelope(_ text: String) -> (Int, Substring) {
            let tail = text.suffix(64)
            return (text.count, tail)
        }

        switch (lhs, rhs) {
        case let (.message(left), .message(right)):
            return envelope(left.plainText) == envelope(right.plainText)
        case let (.toolCall(left), .toolCall(right)):
            let leftSignature = toolCallEnvelopeText(left.toolCall)
            let rightSignature = toolCallEnvelopeText(right.toolCall)
            return envelope(leftSignature) == envelope(rightSignature)
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

    private func hasTrailingDuplicateContent(existing: [ContentBlock], appended: [ContentBlock]) -> Bool {
        guard !existing.isEmpty, !appended.isEmpty, existing.count >= appended.count else {
            return false
        }

        let trailing = existing.suffix(appended.count)
        for (lhs, rhs) in zip(trailing, appended) {
            guard contentBlockFingerprint(lhs) == contentBlockFingerprint(rhs) else {
                return false
            }
        }
        return true
    }

    private func updateSignature(_ update: SessionUpdateNotification) -> String {
        guard let data = try? JSONEncoder().encode(update.update) else {
            return UUID().uuidString
        }
        return "\(update.sessionId.value)|\(data.base64EncodedString())"
    }

    private func finishStreamingCycle(forceRebuild: Bool) {
        messageFlushTask?.cancel()
        messageFlushTask = nil
        toolCallFlushTask?.cancel()
        toolCallFlushTask = nil

        flushPendingAgentChunks()
        flushPendingToolCallTimelineUpdates()

        isStreaming = false
        currentThought = ""

        let shouldRebuild = forceRebuild || pendingStreamingRebuild
        pendingStreamingRebuild = false
        if shouldRebuild {
            rebuildTimelineWithGrouping(isStreaming: false)
        }
    }

}
