import Foundation
import GRDB
import SwiftUI

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
    var remoteId: String? = nil
    var repoId: String? = nil

    static let databaseTableName = "projects"

    enum Columns: String, ColumnExpression {
        case id
        case name
        case remotePath = "remote_path"
        case defaultBranch = "default_branch"
        case presets = "presets_json"
        case remoteId = "remote_id"
        case repoId = "repo_id"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case remotePath = "remote_path"
        case defaultBranch = "default_branch"
        case presets = "presets_json"
        case remoteId = "remote_id"
        case repoId = "repo_id"
    }
}

extension Project {
    private static let avatarPalette: [Color] = [.purple, .green, .teal, .pink, .blue, .orange, .red, .indigo, .mint, .cyan]

    var avatarColorIndex: Int {
        let hash = name.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
        return hash % Self.avatarPalette.count
    }

    var avatarColor: Color {
        Self.avatarPalette[avatarColorIndex]
    }

    var avatarLetter: String {
        String(name.prefix(1)).uppercased()
    }
}
