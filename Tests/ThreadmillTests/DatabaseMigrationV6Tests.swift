import Foundation
import GRDB
import XCTest
@testable import Threadmill

@MainActor
final class DatabaseMigrationV6Tests: XCTestCase {
    func testLegacyConversationColumnsMigrateToAgentSessionFields() throws {
        let dbPath = try makeTempDatabasePath()
        try seedLegacyDatabase(at: dbPath)

        let database = try DatabaseManager(databasePath: dbPath)
        let migrated = try XCTUnwrap(try database.conversation(id: "conv-1"))
        XCTAssertEqual(migrated.agentSessionID, "ses-legacy")
        XCTAssertEqual(migrated.agentType, "opencode")

        let migratedQueue = try DatabaseQueue(path: dbPath)
        let columns = try migratedQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('chatConversation')")
        }

        XCTAssertTrue(columns.contains("agentSessionID"))
        XCTAssertTrue(columns.contains("agentType"))
        XCTAssertFalse(columns.contains("opencodeSessionID"))
    }

    private func seedLegacyDatabase(at path: String) throws {
        let dbQueue = try DatabaseQueue(path: path)

        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY, appliedAt TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")

            let legacyMigrations = [
                "v1",
                "v2_project_presets",
                "v3_thread_port_offset",
                "v4_chat_conversation",
                "v5_browser_session",
                "v6_remote_model",
                "v7_repo_model",
                "v8_remote_default_flag",
            ]

            for identifier in legacyMigrations {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }

            try db.execute(
                sql: """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    default_branch TEXT NOT NULL,
                    presets_json TEXT NOT NULL DEFAULT '[]',
                    remote_id TEXT,
                    repo_id TEXT
                )
                """
            )

            try db.execute(
                sql: """
                CREATE TABLE chatConversation (
                    id TEXT NOT NULL PRIMARY KEY,
                    threadID TEXT NOT NULL,
                    opencodeSessionID TEXT,
                    title TEXT NOT NULL DEFAULT '',
                    createdAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL,
                    isArchived BOOLEAN NOT NULL DEFAULT 0
                )
                """
            )

            try db.execute(
                sql: "INSERT INTO chatConversation (id, threadID, opencodeSessionID, title, createdAt, updatedAt, isArchived) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: ["conv-1", "thread-1", "ses-legacy", "Legacy", 1.0, 1.0, 0]
            )
        }
    }

    private func makeTempDatabasePath() throws -> String {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("threadmill.db", isDirectory: false).path
    }
}
