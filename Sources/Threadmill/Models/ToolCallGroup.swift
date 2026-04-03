import ACPModel
import Foundation

struct ExplorationCluster: Identifiable {
    let id: String
    let toolCalls: [ToolCallTimelineItem]

    var summaryText: String {
        "Explored \(toolCalls.count) files"
    }
}

enum ToolCallGroupDisplayItem: Identifiable {
    case toolCall(ToolCallTimelineItem)
    case exploration(ExplorationCluster)

    var id: String {
        switch self {
        case let .toolCall(toolCall):
            return "tool-call:\(toolCall.id)"
        case let .exploration(cluster):
            return "exploration:\(cluster.id)"
        }
    }
}

struct ToolCallGroup: Identifiable {
    let id: String
    let toolCalls: [ToolCallTimelineItem]
    let displayItems: [ToolCallGroupDisplayItem]
    let timestamp: Date
    let isStreaming: Bool

    /// Wall-clock duration: earliest startedAt → latest completedAt.
    /// Not the sum — parallel tool calls overlap.
    var durationSeconds: Double? {
        let earliest = toolCalls.map(\.startedAt).min()
        let latest = toolCalls.compactMap(\.completedAt).max()
        guard let earliest, let latest else { return nil }
        return latest.timeIntervalSince(earliest)
    }

    init(id: String, toolCalls: [ToolCallTimelineItem], isStreaming: Bool) {
        self.id = id
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
        timestamp = toolCalls.map(\.timestamp).min() ?? Date()
        displayItems = ToolCallGroup.buildDisplayItems(toolCalls: toolCalls, isStreaming: isStreaming)
    }

    private static func buildDisplayItems(toolCalls: [ToolCallTimelineItem], isStreaming: Bool) -> [ToolCallGroupDisplayItem] {
        guard isStreaming else {
            return toolCalls.map(ToolCallGroupDisplayItem.toolCall)
        }

        var items: [ToolCallGroupDisplayItem] = []
        var explorationBuffer: [ToolCallTimelineItem] = []

        func flushExplorationBuffer() {
            guard !explorationBuffer.isEmpty else {
                return
            }

            if explorationBuffer.count == 1 {
                items.append(.toolCall(explorationBuffer[0]))
            } else {
                let firstID = explorationBuffer[0].id
                items.append(.exploration(ExplorationCluster(id: firstID, toolCalls: explorationBuffer)))
            }
            explorationBuffer.removeAll(keepingCapacity: true)
        }

        for toolCall in toolCalls {
            if toolCall.isExplorationCandidate {
                explorationBuffer.append(toolCall)
            } else {
                flushExplorationBuffer()
                items.append(.toolCall(toolCall))
            }
        }

        flushExplorationBuffer()
        return items
    }
}

private extension ToolCallTimelineItem {
    var isExplorationCandidate: Bool {
        if let kind = toolCall.kind, kind == .read || kind == .search {
            return true
        }

        let query = [
            toolCall.title,
            toolCall.kind?.rawValue,
            toolCall.rawInput?.searchableText,
            toolCall.rawOutput?.searchableText,
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return Self.explorationKeywords.contains { query.contains($0) }
    }

    static let explorationKeywords = ["read", "search", "grep", "list", "find", "glob", "ls", "fd", "rg"]
}

private extension AnyCodable {
    var searchableText: String {
        switch value {
        case let string as String:
            return string
        case let array as [any Sendable]:
            return array.map { AnyCodable($0).searchableText }.joined(separator: " ")
        case let dictionary as [String: any Sendable]:
            return dictionary
                .map { "\($0.key) \(AnyCodable($0.value).searchableText)" }
                .joined(separator: " ")
        default:
            return ""
        }
    }
}
