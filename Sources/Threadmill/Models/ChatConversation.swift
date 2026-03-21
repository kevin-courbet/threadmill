import Foundation
import GRDB

struct ChatConversation: Codable, Identifiable, FetchableRecord, PersistableRecord, Equatable {
    var id: String
    var threadID: String
    var agentSessionID: String?
    var agentType: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    static var databaseTableName: String { "chatConversation" }

    enum Columns: String, ColumnExpression {
        case id
        case threadID
        case agentSessionID
        case agentType
        case title
        case createdAt
        case updatedAt
        case isArchived
    }

    init(threadID: String, title: String = "") {
        id = UUID().uuidString
        self.threadID = threadID
        agentSessionID = nil
        agentType = "opencode"
        self.title = title
        createdAt = Date()
        updatedAt = Date()
        isArchived = false
    }

    init(
        id: String,
        threadID: String,
        agentSessionID: String?,
        agentType: String = "opencode",
        title: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        isArchived: Bool
    ) {
        self.id = id
        self.threadID = threadID
        self.agentSessionID = agentSessionID
        self.agentType = agentType
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
            .filter(Columns.agentSessionID != nil)
            .order(Columns.updatedAt.desc)
            .fetchAll(db)
    }

    static func activeForThread(_ threadID: String, in db: Database) throws -> [ChatConversation] {
        try ChatConversation
            .filter(Columns.threadID == threadID)
            .filter(Columns.isArchived == false)
            .filter(Columns.agentSessionID != nil)
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
        agentSessionID = sessionID
        updatedAt = Date()
    }
}
