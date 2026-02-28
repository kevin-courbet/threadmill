import Foundation
import GRDB

struct ChatConversation: Codable, Identifiable, FetchableRecord, PersistableRecord, Equatable {
    var id: String
    var threadID: String
    var opencodeSessionID: String?
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    static var databaseTableName: String { "chatConversation" }

    enum Columns: String, ColumnExpression {
        case id
        case threadID
        case opencodeSessionID
        case title
        case createdAt
        case updatedAt
        case isArchived
    }

    init(threadID: String, title: String = "") {
        id = UUID().uuidString
        self.threadID = threadID
        opencodeSessionID = nil
        self.title = title
        createdAt = Date()
        updatedAt = Date()
        isArchived = false
    }

    init(
        id: String,
        threadID: String,
        opencodeSessionID: String?,
        title: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        isArchived: Bool
    ) {
        self.id = id
        self.threadID = threadID
        self.opencodeSessionID = opencodeSessionID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isArchived = isArchived
    }
}

extension ChatConversation {
    static func listForThread(_ threadID: String, in db: Database) throws -> [ChatConversation] {
        try ChatConversation
            .filter(Columns.threadID == threadID)
            .order(Columns.updatedAt.desc)
            .fetchAll(db)
    }

    static func activeForThread(_ threadID: String, in db: Database) throws -> [ChatConversation] {
        try ChatConversation
            .filter(Columns.threadID == threadID)
            .filter(Columns.isArchived == false)
            .order(Columns.updatedAt.desc)
            .fetchAll(db)
    }

    mutating func updateTitle(_ title: String) {
        self.title = title
        updatedAt = Date()
    }

    mutating func archive() {
        isArchived = true
        updatedAt = Date()
    }

    mutating func linkSession(_ sessionID: String) {
        opencodeSessionID = sessionID
        updatedAt = Date()
    }
}
