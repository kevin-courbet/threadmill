import Foundation
import GRDB

struct Remote: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    var daemonPort: Int
    var useSSHTunnel: Bool
    var cloneRoot: String
    var isDefault: Bool = false

    static let databaseTableName = "remotes"

    enum Columns: String, ColumnExpression {
        case id
        case name
        case host
        case daemonPort = "daemon_port"
        case useSSHTunnel = "use_ssh_tunnel"
        case cloneRoot = "clone_root"
        case isDefault = "is_default"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case daemonPort = "daemon_port"
        case useSSHTunnel = "use_ssh_tunnel"
        case cloneRoot = "clone_root"
        case isDefault = "is_default"
    }
}

extension Remote {
    static func joinedRemotePath(root: String, owner: String, repoName: String) -> String {
        let normalizedRoot: String
        if root.isEmpty || root == "/" {
            normalizedRoot = ""
        } else {
            normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        }

        if normalizedRoot.isEmpty {
            return "/\(owner)/\(repoName)"
        }
        return "\(normalizedRoot)/\(owner)/\(repoName)"
    }
}
