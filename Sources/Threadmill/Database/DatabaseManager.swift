import Foundation
import GRDB

@MainActor
final class DatabaseManager: DatabaseManaging {
    struct RemoteDefaults {
        static let beastName = "beast"
        static let beastHost = "beast"
        static let beastDaemonPort = 19990
        static let beastUseSSHTunnel = true
        static let beastCloneRoot = "/home/wsl/dev"
    }

    private struct RemoteConfigEntry: Decodable {
        let name: String
        let host: String
        let daemonPort: Int
        let useSSHTunnel: Bool
        let cloneRoot: String
    }

    private let dbQueue: DatabaseQueue

    init(databasePath: String? = nil) throws {
        let fileManager = FileManager.default
        let databaseURL: URL

        if let databasePath, !databasePath.isEmpty {
            databaseURL = URL(fileURLWithPath: databasePath)
            try fileManager.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        } else if let overridePath = ProcessInfo.processInfo.environment["THREADMILL_DB_PATH"], !overridePath.isEmpty {
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

    func allRemotes() throws -> [Remote] {
        try dbQueue.read { db in
            try Remote.order(Remote.Columns.name.asc).fetchAll(db)
        }
    }

    func allRepos() throws -> [Repo] {
        try dbQueue.read { db in
            try Repo.order(Repo.Columns.fullName.asc).fetchAll(db)
        }
    }

    func remote(id: String) throws -> Remote? {
        try dbQueue.read { db in
            try Remote.fetchOne(db, key: id)
        }
    }

    func repo(id: String) throws -> Repo? {
        try dbQueue.read { db in
            try Repo.fetchOne(db, key: id)
        }
    }

    func saveRemote(_ remote: Remote) throws {
        try dbQueue.write { db in
            try remote.save(db)
        }
    }

    func saveRepo(_ repo: Repo) throws {
        try dbQueue.write { db in
            try repo.save(db)
        }
    }

    func deleteRemote(id: String) throws {
        try dbQueue.write { db in
            _ = try Remote.deleteOne(db, key: id)
        }
    }

    func deleteRepo(id: String) throws {
        try dbQueue.write { db in
            _ = try Repo.deleteOne(db, key: id)
        }
    }

    func replaceAllRepos(_ repos: [Repo]) throws {
        try dbQueue.write { db in
            try Repo.deleteAll(db)
            for repo in repos {
                try repo.insert(db)
            }
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

    func saveConversation(_ conversation: ChatConversation) throws {
        try dbQueue.write { db in
            try conversation.save(db)
        }
    }

    func conversation(id: String) throws -> ChatConversation? {
        try dbQueue.read { db in
            try ChatConversation.fetchOne(db, key: id)
        }
    }

    func listConversations(threadID: String) throws -> [ChatConversation] {
        try dbQueue.read { db in
            try ChatConversation.listForThread(threadID, in: db)
        }
    }

    func activeConversations(threadID: String) throws -> [ChatConversation] {
        try dbQueue.read { db in
            try ChatConversation.activeForThread(threadID, in: db)
        }
    }

    func saveBrowserSession(_ session: BrowserSession) throws {
        try dbQueue.write { db in
            try session.save(db)
        }
    }

    func deleteBrowserSession(id: String) throws {
        try dbQueue.write { db in
            _ = try BrowserSession.deleteOne(db, key: id)
        }
    }

    func listBrowserSessions(threadID: String) throws -> [BrowserSession] {
        try dbQueue.read { db in
            try BrowserSession.listForThread(threadID, in: db)
        }
    }

    func replaceAllFromDaemon(projects: [Project], threads: [ThreadModel], remoteId: String) throws {
        try dbQueue.write { db in
            let existingProjectMetadata = try Project.fetchAll(db).reduce(into: [String: (remoteID: String?, repoID: String?)]()) { result, project in
                result[project.id] = (project.remoteId, project.repoId)
            }
            let incomingProjectIDs = Set(projects.map(\.id))
            let incomingThreadIDs = Set(threads.map(\.id))

            for project in projects {
                var projectToPersist = project
                if projectToPersist.remoteId == nil {
                    projectToPersist.remoteId = existingProjectMetadata[project.id]?.remoteID ?? remoteId
                }
                if projectToPersist.repoId == nil {
                    projectToPersist.repoId = existingProjectMetadata[project.id]?.repoID
                }
                try projectToPersist.save(db)
            }

            if incomingProjectIDs.isEmpty {
                _ = try Project
                    .filter(Project.Columns.remoteId == remoteId)
                    .deleteAll(db)
            } else {
                _ = try Project
                    .filter(Project.Columns.remoteId == remoteId && !incomingProjectIDs.contains(Project.Columns.id))
                    .deleteAll(db)

                var staleThreadFilter = incomingProjectIDs.contains(ThreadModel.Columns.projectId)
                if !incomingThreadIDs.isEmpty {
                    staleThreadFilter = staleThreadFilter && !incomingThreadIDs.contains(ThreadModel.Columns.id)
                }
                _ = try ThreadModel
                    .filter(staleThreadFilter)
                    .deleteAll(db)
            }

            for thread in threads {
                try thread.save(db)
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

    func linkProject(projectID: String, repoID: String, remoteID: String) throws -> Bool {
        try dbQueue.write { db in
            let updated = try Project
                .filter(Project.Columns.id == projectID)
                .updateAll(
                    db,
                    Project.Columns.repoId.set(to: repoID),
                    Project.Columns.remoteId.set(to: remoteID)
                )
            return updated > 0
        }
    }

    func syncRemotesFromConfigFile() throws {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("threadmill", isDirectory: true)
            .appendingPathComponent("remotes.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }

        let data = try Data(contentsOf: configURL)
        let entries = try JSONDecoder().decode([RemoteConfigEntry].self, from: data)

        try dbQueue.write { db in
            for entry in entries {
                let existing = try Remote
                    .filter(Remote.Columns.name == entry.name)
                    .fetchOne(db)

                let remote = Remote(
                    id: existing?.id ?? UUID().uuidString,
                    name: entry.name,
                    host: entry.host,
                    daemonPort: entry.daemonPort,
                    useSSHTunnel: entry.useSSHTunnel,
                    cloneRoot: entry.cloneRoot
                )
                try remote.save(db)
            }
        }
    }

    func ensureDefaultRemoteExists() throws -> Remote {
        try dbQueue.write { db in
            if let beast = try Remote
                .filter(Remote.Columns.name == RemoteDefaults.beastName)
                .fetchOne(db)
            {
                return beast
            }

            if let firstRemote = try Remote.order(Remote.Columns.name.asc).fetchOne(db) {
                return firstRemote
            }

            let beastRemote = Remote(
                id: UUID().uuidString,
                name: RemoteDefaults.beastName,
                host: RemoteDefaults.beastHost,
                daemonPort: RemoteDefaults.beastDaemonPort,
                useSSHTunnel: RemoteDefaults.beastUseSSHTunnel,
                cloneRoot: RemoteDefaults.beastCloneRoot
            )
            try beastRemote.insert(db)
            return beastRemote
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

        migrator.registerMigration("v6_remote_model") { db in
            let beastRemote = Remote(
                id: UUID().uuidString,
                name: RemoteDefaults.beastName,
                host: RemoteDefaults.beastHost,
                daemonPort: RemoteDefaults.beastDaemonPort,
                useSSHTunnel: RemoteDefaults.beastUseSSHTunnel,
                cloneRoot: RemoteDefaults.beastCloneRoot
            )

            try db.create(table: "remotes") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull().unique(onConflict: .replace)
                table.column("host", .text).notNull()
                table.column("daemon_port", .integer).notNull()
                table.column("use_ssh_tunnel", .boolean).notNull()
                table.column("clone_root", .text).notNull()
            }

            try beastRemote.insert(db)

            try db.alter(table: "projects") { table in
                table.add(column: "remote_id", .text).indexed().references("remotes", onDelete: .setNull)
            }

            try db.execute(
                sql: "UPDATE projects SET remote_id = ? WHERE remote_id IS NULL",
                arguments: [beastRemote.id]
            )
        }

        migrator.registerMigration("v7_repo_model") { db in
            try db.create(table: "repos") { table in
                table.column("id", .text).primaryKey()
                table.column("owner", .text).notNull()
                table.column("name", .text).notNull()
                table.column("full_name", .text).notNull().unique(onConflict: .replace)
                table.column("clone_url", .text).notNull()
                table.column("default_branch", .text).notNull()
                table.column("is_private", .boolean).notNull()
                table.column("cached_at", .datetime).notNull()
            }

            try db.alter(table: "projects") { table in
                table.add(column: "repo_id", .text).indexed().references("repos", onDelete: .setNull)
            }
        }

        try migrator.migrate(dbQueue)
    }

}
