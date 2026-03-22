import Foundation

enum ChatHarness: String, CaseIterable, Identifiable {
    case opencode = "opencode"
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .opencode:
            return "OpenCode"
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini"
        }
    }

    /// The agent type stored in ChatConversation.agentType
    var agentType: String {
        rawValue
    }
}
