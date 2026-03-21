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
            return
        }
        content.append(block)
    }
}

struct ToolCallTimelineItem: Identifiable {
    var toolCall: ToolCall

    var id: String { toolCall.id }
    var timestamp: Date { toolCall.timestamp }
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

    var id: String {
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
