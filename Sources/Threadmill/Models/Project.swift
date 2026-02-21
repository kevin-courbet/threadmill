import Foundation
import GRDB

struct Project: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var name: String
    var remotePath: String
    var defaultBranch: String

    static let databaseTableName = "projects"

    enum Columns: String, ColumnExpression {
        case id
        case name
        case remotePath = "remote_path"
        case defaultBranch = "default_branch"
    }
}
