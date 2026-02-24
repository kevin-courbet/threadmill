import Foundation
import GRDB

struct PresetConfig: Codable, Equatable {
    var name: String
    var command: String
    var cwd: String?
}

struct Project: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var name: String
    var remotePath: String
    var defaultBranch: String
    var presets: [PresetConfig] = []

    static let databaseTableName = "projects"

    enum Columns: String, ColumnExpression {
        case id
        case name
        case remotePath = "remote_path"
        case defaultBranch = "default_branch"
        case presets = "presets_json"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case remotePath = "remote_path"
        case defaultBranch = "default_branch"
        case presets = "presets_json"
    }
}
