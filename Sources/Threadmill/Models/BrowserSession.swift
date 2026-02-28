import Foundation
import GRDB

struct BrowserSession: Codable, Identifiable, FetchableRecord, PersistableRecord, Equatable {
    var id: String
    var threadID: String
    var url: String
    var title: String
    var order: Int
    var createdAt: Date

    static var databaseTableName: String { "browserSession" }

    enum Columns: String, ColumnExpression {
        case id
        case threadID
        case url
        case title
        case order
        case createdAt
    }

    init(
        id: String = UUID().uuidString,
        threadID: String,
        url: String,
        title: String = "",
        order: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.url = url
        self.title = title
        self.order = order
        self.createdAt = createdAt
    }
}

extension BrowserSession {
    static func listForThread(_ threadID: String, in db: Database) throws -> [BrowserSession] {
        try BrowserSession
            .filter(Columns.threadID == threadID)
            .order(Columns.order.asc, Columns.createdAt.asc)
            .fetchAll(db)
    }
}
