import Foundation

enum TerminalTabType: Equatable {
    case terminal(Preset)
    case chat
}

struct TerminalTabModel: Identifiable {
    static let chatTabSelectionID = "__threadmill_chat__"

    let threadID: String
    let type: TerminalTabType
    let endpoint: RelayEndpoint?

    var id: String {
        "\(threadID)::\(selectionID)"
    }

    var selectionID: String {
        switch type {
        case let .terminal(preset):
            preset.name
        case .chat:
            Self.chatTabSelectionID
        }
    }

    var title: String {
        switch type {
        case let .terminal(preset):
            preset.label
        case .chat:
            "Chat"
        }
    }

    var preset: Preset? {
        guard case let .terminal(preset) = type else {
            return nil
        }
        return preset
    }

    var isClosable: Bool {
        if case .terminal = type {
            return true
        }
        return false
    }

    @MainActor var isAttached: Bool { endpoint?.channelID ?? 0 > 0 }
}
