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

enum AgentInstallMethod: Codable, Hashable {
    case npm(package: String)
    case uv(package: String)

    enum CodingKeys: String, CodingKey {
        case type
        case package
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let package = try container.decode(String.self, forKey: .package)
        switch type {
        case "npm":
            self = .npm(package: package)
        case "uv":
            self = .uv(package: package)
        default:
            self = .npm(package: package)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .npm(package):
            try container.encode("npm", forKey: .type)
            try container.encode(package, forKey: .package)
        case let .uv(package):
            try container.encode("uv", forKey: .type)
            try container.encode(package, forKey: .package)
        }
    }

    var displayLabel: String {
        switch self {
        case let .npm(package): return "npm: \(package)"
        case let .uv(package): return "uv: \(package)"
        }
    }
}

struct AgentRegistryEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let command: String
    let launchArgs: [String]
    let installed: Bool
    let resolvedPath: String?
    let installMethod: AgentInstallMethod?

    enum CodingKeys: String, CodingKey {
        case id, name, command, installed
        case launchArgs = "launch_args"
        case resolvedPath = "resolved_path"
        case installMethod = "install_method"
    }

    var toAgentConfig: AgentConfig {
        AgentConfig(name: id, command: command, cwd: nil)
    }
}
