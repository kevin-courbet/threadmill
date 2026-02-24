import Foundation

@MainActor
final class SyncService {
    private let connectionManager: ConnectionManager
    private let databaseManager: DatabaseManager
    private let appState: AppState
    private let formatter: ISO8601DateFormatter

    init(connectionManager: ConnectionManager, databaseManager: DatabaseManager, appState: AppState) {
        self.connectionManager = connectionManager
        self.databaseManager = databaseManager
        self.appState = appState
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func syncFromDaemon() async {
        do {
            let projectsResult = try await connectionManager.request(method: "project.list", timeout: 10)
            let threadsResult = try await connectionManager.request(method: "thread.list", params: [:], timeout: 10)

            let projects = parseProjects(projectsResult)
            let threads = parseThreads(threadsResult)
            try databaseManager.replaceAllFromDaemon(projects: projects, threads: threads)
            appState.reloadFromDatabase()
        } catch {
            NSLog("threadmill-sync: sync failed: %@", "\(error)")
        }
    }

    private func parseProjects(_ payload: Any) -> [Project] {
        guard let rows = payload as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard
                let id = row["id"] as? String,
                let name = row["name"] as? String,
                let remotePath = row["path"] as? String ?? row["remote_path"] as? String,
                let defaultBranch = row["default_branch"] as? String ?? row["defaultBranch"] as? String
            else {
                return nil
            }
            return Project(id: id, name: name, remotePath: remotePath, defaultBranch: defaultBranch)
        }
    }

    private func parseThreads(_ payload: Any) -> [ThreadModel] {
        guard let rows = payload as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard
                let id = row["id"] as? String,
                let projectId = row["project_id"] as? String ?? row["projectId"] as? String,
                let name = row["name"] as? String,
                let branch = row["branch"] as? String,
                let worktreePath = row["worktree_path"] as? String ?? row["worktreePath"] as? String,
                let statusRaw = row["status"] as? String,
                let status = ThreadStatus(rawValue: statusRaw),
                let sourceType = row["source_type"] as? String ?? row["sourceType"] as? String,
                let createdAt = parseDate(row["created_at"])
            else {
                return nil
            }

            return ThreadModel(
                id: id,
                projectId: projectId,
                name: name,
                branch: branch,
                worktreePath: worktreePath,
                status: status,
                sourceType: sourceType,
                createdAt: createdAt,
                tmuxSession: row["tmux_session"] as? String ?? ""
            )
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        guard let text = value as? String else {
            return nil
        }
        if let date = formatter.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }
}
