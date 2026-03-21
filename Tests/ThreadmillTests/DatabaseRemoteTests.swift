import Foundation
import GRDB
import XCTest
@testable import Threadmill

@MainActor
final class DatabaseRemoteTests: XCTestCase {
    func testRemoteRoundTripSaveFetchDelete() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let remote = Remote(
            id: UUID().uuidString,
            name: "staging",
            host: "staging-box",
            daemonPort: 20001,
            useSSHTunnel: true,
            cloneRoot: "/srv/dev"
        )

        try database.saveRemote(remote)

        XCTAssertEqual(try database.remote(id: remote.id), remote)

        try database.deleteRemote(id: remote.id)

        XCTAssertNil(try database.remote(id: remote.id))
    }

    func testMigrationV6CreatesRemotesAndSeedsBeast() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let remotes = try database.allRemotes()
        let beast = try XCTUnwrap(remotes.first { $0.name == "beast" })

        XCTAssertEqual(beast.host, "beast")
        XCTAssertEqual(beast.daemonPort, 19990)
        XCTAssertTrue(beast.useSSHTunnel)
        XCTAssertEqual(beast.cloneRoot, "/home/wsl/dev")
        XCTAssertTrue(beast.isDefault)
    }

    func testSaveRemoteEnforcesSingleDefaultRemote() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let secondary = Remote(
            id: UUID().uuidString,
            name: "secondary",
            host: "secondary-host",
            daemonPort: 20002,
            useSSHTunnel: true,
            cloneRoot: "/srv/dev",
            isDefault: true
        )

        try database.saveRemote(secondary)

        let remotes = try database.allRemotes()
        XCTAssertEqual(remotes.filter(\.isDefault).count, 1)
        XCTAssertTrue(remotes.contains(where: { $0.id == secondary.id && $0.isDefault }))
    }

    func testMigrationV6BackfillsProjectsRemoteID() throws {
        let dbPath = try makeTempDatabasePath()
        let dbQueue = try DatabaseQueue(path: dbPath)
        try applyLegacyMigrationsUpToV5(dbQueue)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO projects (id, name, remote_path, default_branch, presets_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["project-1", "demo", "/home/wsl/dev/demo", "main", "[]"]
            )
        }

        let database = try DatabaseManager(databasePath: dbPath)
        let project = try XCTUnwrap(try database.allProjects().first(where: { $0.id == "project-1" }))
        let beast = try XCTUnwrap(try database.allRemotes().first(where: { $0.name == "beast" }))

        XCTAssertEqual(project.remoteId, beast.id)
    }

    func testEnsureDefaultRemoteExistsSeedsBeastWhenTableIsEmpty() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        for remote in try database.allRemotes() {
            try database.deleteRemote(id: remote.id)
        }
        XCTAssertTrue(try database.allRemotes().isEmpty)

        let defaultRemote = try database.ensureDefaultRemoteExists()

        XCTAssertEqual(defaultRemote.name, DatabaseManager.RemoteDefaults.beastName)
        XCTAssertEqual(defaultRemote.host, DatabaseManager.RemoteDefaults.beastHost)
        XCTAssertEqual(defaultRemote.daemonPort, DatabaseManager.RemoteDefaults.beastDaemonPort)
        XCTAssertEqual(defaultRemote.useSSHTunnel, DatabaseManager.RemoteDefaults.beastUseSSHTunnel)
        XCTAssertEqual(defaultRemote.cloneRoot, DatabaseManager.RemoteDefaults.beastCloneRoot)
        XCTAssertTrue(defaultRemote.isDefault)
        XCTAssertEqual(try database.allRemotes(), [defaultRemote])
    }

    func testSavingDuplicateRemoteNameThrowsAndKeepsExistingReferences() throws {
        let dbPath = try makeTempDatabasePath()
        let database = try DatabaseManager(databasePath: dbPath)

        let existingRemote = Remote(
            id: "remote-existing",
            name: "staging",
            host: "staging-a",
            daemonPort: 20001,
            useSSHTunnel: true,
            cloneRoot: "/srv/dev-a"
        )
        try database.saveRemote(existingRemote)

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/srv/dev-a/demo",
            defaultBranch: "main",
            presets: [],
            agents: [],
            remoteId: existingRemote.id,
            repoId: nil
        )
        try database.replaceAllFromDaemon(projects: [project], threads: [], remoteId: existingRemote.id)

        let duplicateNameRemote = Remote(
            id: "remote-duplicate",
            name: "staging",
            host: "staging-b",
            daemonPort: 20002,
            useSSHTunnel: true,
            cloneRoot: "/srv/dev-b"
        )

        XCTAssertThrowsError(try database.saveRemote(duplicateNameRemote))

        let persistedProject = try XCTUnwrap(try database.allProjects().first(where: { $0.id == project.id }))
        XCTAssertEqual(persistedProject.remoteId, existingRemote.id)
        XCTAssertEqual(try database.remote(id: existingRemote.id), existingRemote)
        XCTAssertNil(try database.remote(id: duplicateNameRemote.id))
    }

    private func makeTempDatabasePath() throws -> String {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("threadmill.db", isDirectory: false).path
    }

    private func applyLegacyMigrationsUpToV5(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "projects") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("remote_path", .text).notNull()
                table.column("default_branch", .text).notNull()
            }

            try db.create(table: "threads") { table in
                table.column("id", .text).primaryKey()
                table.column("project_id", .text).notNull().indexed().references("projects", onDelete: .cascade)
                table.column("name", .text).notNull()
                table.column("branch", .text).notNull()
                table.column("worktree_path", .text).notNull()
                table.column("status", .text).notNull()
                table.column("source_type", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("tmux_session", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v2_project_presets") { db in
            try db.alter(table: "projects") { table in
                table.add(column: "presets_json", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v3_thread_port_offset") { db in
            try db.alter(table: "threads") { table in
                table.add(column: "port_offset", .integer)
            }
        }

        migrator.registerMigration("v4_chat_conversation") { db in
            try db.create(table: "chatConversation") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("threadID", .text).notNull()
                table.column("opencodeSessionID", .text)
                table.column("title", .text).notNull().defaults(to: "")
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_chatConversation_threadID", on: "chatConversation", columns: ["threadID"])
        }

        migrator.registerMigration("v5_browser_session") { db in
            try db.create(table: "browserSession") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("threadID", .text).notNull()
                table.column("url", .text).notNull().defaults(to: "")
                table.column("title", .text).notNull().defaults(to: "")
                table.column("order", .integer).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_browserSession_threadID", on: "browserSession", columns: ["threadID"])
        }

        try migrator.migrate(dbQueue)
    }
}
