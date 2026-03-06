import Foundation
import GRDB
import SwiftUI

struct Repo: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var owner: String
    var name: String
    var fullName: String
    var cloneURL: String
    var defaultBranch: String
    var isPrivate: Bool
    var cachedAt: Date

    static let databaseTableName = "repos"

    enum Columns: String, ColumnExpression {
        case id
        case owner
        case name
        case fullName = "full_name"
        case cloneURL = "clone_url"
        case defaultBranch = "default_branch"
        case isPrivate = "is_private"
        case cachedAt = "cached_at"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case fullName = "full_name"
        case cloneURL = "clone_url"
        case defaultBranch = "default_branch"
        case isPrivate = "is_private"
        case cachedAt = "cached_at"
    }
}

extension Repo {
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
