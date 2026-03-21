import ACPModel
import Foundation
import Observation

@MainActor
@Observable
final class ChatSessionViewModel {
    var timelineItems: [TimelineItem] = []
    var itemIndex: [String: Int] = [:]

    var isStreaming = false
    var currentMode: String?
    var availableModes: [ModeInfo]
    var selectedAgentName: String
    var availableAgents: [AgentConfig]
    var sessionTitle: String?

    var userMessages: [MessageTimelineItem] = []
    var agentMessages: [MessageTimelineItem] = []
    var toolCallsByID: [String: ToolCallTimelineItem] = [:]

    private let agentSessionManager: AgentSessionManager?
    private(set) var sessionID: String?
    private let threadID: String?
    private let streamingUserMessageID = "streaming-user"
    private let streamingAgentMessageID = "streaming-agent"

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
            self.handleSessionUpdate(update)
        }
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
            } catch {
                return
            }
        } else if let threadID, let agentSessionManager {
            do {
                sessionID = try await agentSessionManager.startSession(agentConfig: selectedAgent, threadID: threadID)
            } catch {
                return
            }
        }

        selectedAgentName = name
    }

    func setMode(_ modeID: String) async {
        guard let sessionID, let agentSessionManager else {
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
        guard !trimmed.isEmpty, let sessionID, let agentSessionManager else {
            return
        }

        isStreaming = true

        do {
            try await agentSessionManager.sendPrompt(text: trimmed, sessionID: sessionID)
        } catch {
            isStreaming = false
            return
        }

        isStreaming = false
        rebuildTimelineWithGrouping(isStreaming: false)
    }

    func cancelCurrentPrompt() async {
        guard let sessionID, let agentSessionManager else {
            return
        }

        do {
            try await agentSessionManager.cancelPrompt(sessionID: sessionID)
        } catch {
            return
        }

        isStreaming = false
        rebuildTimelineWithGrouping(isStreaming: false)
    }

    func handleSessionUpdate(_ update: SessionUpdateNotification) {
        switch update.update {
        case let .userMessageChunk(content):
            upsertStreamingMessage(role: .user, content: content, messageID: streamingUserMessageID)
        case let .agentMessageChunk(content):
            isStreaming = true
            upsertStreamingMessage(role: .assistant, content: content, messageID: streamingAgentMessageID)
        case .agentThoughtChunk:
            break
        case let .toolCall(toolCallUpdate):
            upsertToolCall(from: toolCallUpdate)
            rebuildTimelineWithGrouping(isStreaming: isStreaming)
        case let .toolCallUpdate(toolCallUpdate):
            applyToolCallUpdate(toolCallUpdate)
            rebuildTimelineWithGrouping(isStreaming: isStreaming)
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
        let messageTimestamp = Date()
        var updatedMessage: MessageTimelineItem

        if role == .assistant, let index = agentMessages.firstIndex(where: { $0.id == messageID }) {
            var message = agentMessages[index]
            message.append(content)
            message.timestamp = messageTimestamp
            agentMessages[index] = message
            updatedMessage = message
        } else if role == .user, let index = userMessages.firstIndex(where: { $0.id == messageID }) {
            var message = userMessages[index]
            message.append(content)
            message.timestamp = messageTimestamp
            userMessages[index] = message
            updatedMessage = message
        } else {
            let message = MessageTimelineItem(id: messageID, role: role, content: [content], timestamp: messageTimestamp)
            if role == .assistant {
                agentMessages.append(message)
            } else {
                userMessages.append(message)
            }
            updatedMessage = message
        }

        let timelineID = "message:\(messageID)"
        if let existingIndex = itemIndex[timelineID], timelineItems.indices.contains(existingIndex) {
            timelineItems[existingIndex] = .message(updatedMessage)
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
        toolCallsByID[id] = ToolCallTimelineItem(toolCall: toolCall)
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

        toolCallsByID[update.toolCallId] = ToolCallTimelineItem(toolCall: existing)
    }

    private func rebuildItemIndex() {
        itemIndex = Dictionary(uniqueKeysWithValues: timelineItems.enumerated().map { index, item in
            (item.id, index)
        })
    }
}
