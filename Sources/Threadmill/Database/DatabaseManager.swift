import Foundation
import GRDB

@MainActor
final class DatabaseManager: DatabaseManaging {
    private let dbQueue: DatabaseQueue

    init() throws {
        let fileManager = FileManager.default
        let databaseURL: URL

        if let overridePath = ProcessInfo.processInfo.environment["THREADMILL_DB_PATH"], !overridePath.isEmpty {
            databaseURL = URL(fileURLWithPath: overridePath)
            try fileManager.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        } else {
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directoryURL = appSupportURL.appendingPathComponent("Threadmill", isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            databaseURL = directoryURL.appendingPathComponent("threadmill.db")
        }

        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try migrate()
    }

    func allProjects() throws -> [Project] {
        try dbQueue.read { db in
            try Project.order(Project.Columns.name.asc).fetchAll(db)
        }
    }

    func allThreads() throws -> [ThreadModel] {
        try dbQueue.read { db in
            try ThreadModel.order(ThreadModel.Columns.createdAt.desc).fetchAll(db)
        }
    }

    func threadsForProject(id: String) throws -> [ThreadModel] {
        try dbQueue.read { db in
            try ThreadModel
                .filter(ThreadModel.Columns.projectId == id)
                .order(ThreadModel.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func allActiveThreads() throws -> [ThreadModel] {
        try dbQueue.read { db in
            try ThreadModel
                .filter(ThreadModel.Columns.status == ThreadStatus.active.rawValue)
                .order(ThreadModel.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func replaceAllFromDaemon(projects: [Project], threads: [ThreadModel]) throws {
        try dbQueue.write { db in
            try Project.deleteAll(db)
            try ThreadModel.deleteAll(db)

            for project in projects {
                try project.insert(db)
            }

            for thread in threads {
                try thread.insert(db)
            }
        }
    }

    func updateThreadStatus(threadID: String, status: ThreadStatus) throws -> Bool {
        try dbQueue.write { db in
            let updated = try ThreadModel
                .filter(ThreadModel.Columns.id == threadID)
                .updateAll(db, ThreadModel.Columns.status.set(to: status.rawValue))
            return updated > 0
        }
    }

    private func migrate() throws {
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

        try migrator.migrate(dbQueue)
    }
}
