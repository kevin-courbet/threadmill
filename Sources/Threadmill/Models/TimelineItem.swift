import ACP
import ACPModel
import Foundation

struct MessageTimelineItem: Identifiable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    let id: String
    var role: Role
    var content: [ContentBlock]
    var timestamp: Date
    var renderVersion: Int = 0

    var plainText: String {
        content.compactMap { block in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }
        .joined()
    }

    mutating func append(_ block: ContentBlock) {
        if case let .text(incomingText) = block,
           let lastIndex = content.indices.last,
           case let .text(existingText) = content[lastIndex]
        {
            content[lastIndex] = .text(TextContent(text: existingText.text + incomingText.text))
            renderVersion &+= 1
            return
        }
        content.append(block)
        renderVersion &+= 1
    }

    mutating func append(contentsOf blocks: [ContentBlock]) {
        guard !blocks.isEmpty else {
            return
        }
        for block in blocks {
            append(block)
        }
    }
}

struct ToolCallTimelineItem: Identifiable {
    var toolCall: ToolCall
    var renderVersion: Int = 0
    var startedAt: Date
    var completedAt: Date?

    init(toolCall: ToolCall) {
        self.toolCall = toolCall
        self.startedAt = Date()
    }

    var id: String { toolCall.id }
    var timestamp: Date { toolCall.timestamp }

    var durationSeconds: Double? {
        guard let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }
}

struct TurnSummary: Identifiable {
    let id: String
    let toolCount: Int
    let durationSeconds: Int
    let modifiedFiles: [String]

    static func from(
        id: String,
        toolCalls: [ToolCallTimelineItem],
        startedAt: Date,
        endedAt: Date
    ) -> TurnSummary {
        let fileSet = Set(toolCalls.flatMap { item in
            item.toolCall.locations?.compactMap(\.path) ?? []
        })

        return TurnSummary(
            id: id,
            toolCount: toolCalls.count,
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(startedAt).rounded())),
            modifiedFiles: fileSet.sorted()
        )
    }

    static func from(
        toolCalls: [ToolCallTimelineItem],
        startedAt: Date,
        endedAt: Date
    ) -> TurnSummary {
        from(id: UUID().uuidString, toolCalls: toolCalls, startedAt: startedAt, endedAt: endedAt)
    }
}

enum TimelineItem: Identifiable {
    case message(MessageTimelineItem)
    case toolCall(ToolCallTimelineItem)
    case toolCallGroup(ToolCallGroup)
    case turnSummary(TurnSummary)

    var stableId: String {
        switch self {
        case let .message(message):
            return "message:\(message.id)"
        case let .toolCall(toolCall):
            return "tool-call:\(toolCall.id)"
        case let .toolCallGroup(group):
            return "tool-call-group:\(group.id)"
        case let .turnSummary(summary):
            return "turn-summary:\(summary.id)"
        }
    }

    var renderId: String {
        switch self {
        case let .message(message):
            return "\(stableId):\(message.renderVersion)"
        case let .toolCall(toolCall):
            return "\(stableId):\(toolCall.renderVersion)"
        case let .toolCallGroup(group):
            let aggregateRenderVersion = group.toolCalls.reduce(into: 0) { accumulator, item in
                accumulator &+= item.renderVersion
            }
            return "\(stableId):\(group.toolCalls.count):\(aggregateRenderVersion)"
        case .turnSummary:
            return stableId
        }
    }

    var id: String {
        renderId
    }

    var timestamp: Date {
        switch self {
        case let .message(message):
            return message.timestamp
        case let .toolCall(toolCall):
            return toolCall.timestamp
        case let .toolCallGroup(group):
            return group.timestamp
        case .turnSummary:
            return .distantPast
        }
    }
}
