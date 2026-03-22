import GRDB
import XCTest
@testable import Threadmill

@MainActor
final class ChatConversationTests: XCTestCase {
    func testConversationCRUDLifecycle() throws {
        let dbQueue = try makeDatabaseQueue()
        let threadID = "thread-1"

        let conversation = ChatConversation(threadID: threadID, title: "Initial")
        try dbQueue.write { db in
            try conversation.insert(db)
        }

        try dbQueue.write { db in
            var stored = try XCTUnwrap(try ChatConversation.fetchOne(db, key: conversation.id))
            stored.updateTitle("Updated title")
            stored.linkSession("session-1")
            stored.archive()
            try stored.update(db)
        }

        let storedConversation = try dbQueue.read { db in
            try XCTUnwrap(try ChatConversation.fetchOne(db, key: conversation.id))
        }

        XCTAssertEqual(storedConversation.threadID, threadID)
        XCTAssertEqual(storedConversation.title, "Updated title")
        XCTAssertEqual(storedConversation.agentSessionID, "session-1")
        XCTAssertEqual(storedConversation.agentType, "opencode")
        XCTAssertTrue(storedConversation.isArchived)

        let active = try dbQueue.read { db in
            try ChatConversation.activeForThread(threadID, in: db)
        }
        XCTAssertTrue(active.isEmpty)
    }

    func testListForThreadReturnsMultipleConversations() throws {
        let dbQueue = try makeDatabaseQueue()

        var first = ChatConversation(threadID: "thread-1", title: "First")
        var second = ChatConversation(threadID: "thread-1", title: "Second")
        let otherThread = ChatConversation(threadID: "thread-2", title: "Other")

        try dbQueue.write { db in
            try first.insert(db)
            try second.insert(db)
            try otherThread.insert(db)
            first.linkSession("session-a")
            second.linkSession("session-b")
            try first.update(db)
            try second.update(db)
        }

        let threadConversations = try dbQueue.read { db in
            try ChatConversation.listForThread("thread-1", in: db)
        }

        XCTAssertEqual(threadConversations.count, 2)
        XCTAssertEqual(Set(threadConversations.map(\.agentSessionID)), Set(["session-a", "session-b"]))
    }

    private func makeDatabaseQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        try dbQueue.write { db in
            try db.create(table: "chatConversation") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("threadID", .text).notNull()
                table.column("agentSessionID", .text)
                table.column("agentType", .text).notNull().defaults(to: "opencode")
                table.column("title", .text).notNull().defaults(to: "")
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_chatConversation_threadID", on: "chatConversation", columns: ["threadID"])
        }
        return dbQueue
    }
}
