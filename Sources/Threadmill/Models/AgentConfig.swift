import Foundation

struct AgentConfig: Codable, Identifiable, Hashable {
    let name: String
    let command: String
    let cwd: String?

    var id: String { name }

    var displayName: String {
        AgentConfig.displayName(for: name)
    }

    static func displayName(for rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Agent"
        }

        let normalized = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "-acp", with: "", options: [.caseInsensitive])

        let tokens = normalized
            .split(separator: "-")
            .map { token -> String in
                let lowercase = token.lowercased()
                switch lowercase {
                case "opencode":
                    return "OpenCode"
                case "gpt":
                    return "GPT"
                default:
                    return lowercase.capitalized
                }
            }

        let candidate = tokens.joined(separator: " ")
        return candidate.isEmpty ? trimmed : candidate
    }
}
