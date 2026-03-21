import Foundation

struct AgentConfig: Codable, Identifiable, Hashable {
    let name: String
    let command: String
    let cwd: String?

    var id: String { name }
}
