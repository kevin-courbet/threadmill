import Foundation
import GRDB

struct ThreadModel: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var projectId: String
    var name: String
    var branch: String
    var worktreePath: String
    var status: ThreadStatus
    var sourceType: String
    var createdAt: Date
    var tmuxSession: String

    static let databaseTableName = "threads"

    enum Columns: String, ColumnExpression {
        case id
        case projectId = "project_id"
        case name
        case branch
        case worktreePath = "worktree_path"
        case status
        case sourceType = "source_type"
        case createdAt = "created_at"
        case tmuxSession = "tmux_session"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case name
        case branch
        case worktreePath = "worktree_path"
        case status
        case sourceType = "source_type"
        case createdAt = "created_at"
        case tmuxSession = "tmux_session"
    }
}
