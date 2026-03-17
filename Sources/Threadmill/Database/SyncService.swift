import Foundation

@MainActor
final class SyncService: SyncServicing {
    private struct StateSnapshot {
        let stateVersion: Int
        let projects: [Project]
        let threads: [ThreadModel]
    }

    private enum SyncServiceError: Error {
        case invalidStateSnapshotPayload
    }

    private let connectionManager: any ConnectionManaging
    private let databaseManager: any DatabaseManaging
    private let appState: AppState
    private let remoteId: String
    private let formatter: ISO8601DateFormatter

    // SyncService is intentionally scoped to one connection/remote.
    // Multi-remote fan-out sync is handled separately.
    init(connectionManager: any ConnectionManaging, databaseManager: any DatabaseManaging, appState: AppState, remoteId: String) {
        self.connectionManager = connectionManager
        self.databaseManager = databaseManager
        self.appState = appState
        self.remoteId = remoteId
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func syncFromDaemon() async {
        do {
            let snapshotResult = try await connectionManager.request(method: "state.snapshot", params: nil, timeout: 10)
            let snapshot = try parseStateSnapshot(snapshotResult)
            try databaseManager.replaceAllFromDaemon(projects: snapshot.projects, threads: snapshot.threads, remoteId: remoteId)
            appState.reloadFromDatabase()
            appState.applyDaemonSnapshotStateVersion(snapshot.stateVersion)
        } catch {
            NSLog("threadmill-sync: sync failed: %@", "\(error)")
        }
    }

    private func parseStateSnapshot(_ payload: Any) throws -> StateSnapshot {
        guard
            let row = payload as? [String: Any],
            let stateVersion = parseOptionalInt(row["state_version"]),
            stateVersion >= 0
        else {
            throw SyncServiceError.invalidStateSnapshotPayload
        }

        let projectRows = try parseRows(row["projects"])
        let threadRows = try parseRows(row["threads"])
        let projects = parseProjects(projectRows)
        let threads = parseThreads(threadRows)
        return StateSnapshot(stateVersion: stateVersion, projects: projects, threads: threads)
    }

    private func parseRows(_ payload: Any?) throws -> [[String: Any]] {
        guard let rows = payload as? [[String: Any]] else {
            throw SyncServiceError.invalidStateSnapshotPayload
        }
        return rows
    }

    private func parseProjects(_ rows: [[String: Any]]) -> [Project] {
        return rows.compactMap { row in
            guard
                let id = row["id"] as? String,
                let name = row["name"] as? String,
                let remotePath = row["path"] as? String ?? row["remote_path"] as? String,
                let defaultBranch = row["default_branch"] as? String ?? row["defaultBranch"] as? String
            else {
                return nil
            }
            let presets = parsePresetConfigs(row["presets"])
            return Project(
                id: id,
                name: name,
                remotePath: remotePath,
                defaultBranch: defaultBranch,
                presets: presets,
                remoteId: row["remote_id"] as? String ?? row["remoteId"] as? String,
                repoId: row["repo_id"] as? String ?? row["repoId"] as? String
            )
        }
    }

    private func parsePresetConfigs(_ payload: Any?) -> [PresetConfig] {
        guard let rows = payload as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard
                let name = row["name"] as? String,
                let command = row["command"] as? String
            else {
                return nil
            }

            return PresetConfig(name: name, command: command, cwd: row["cwd"] as? String)
        }
    }

    private func parseThreads(_ rows: [[String: Any]]) -> [ThreadModel] {
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
                tmuxSession: row["tmux_session"] as? String ?? "",
                portOffset: parseOptionalInt(row["port_offset"] ?? row["portOffset"])
            )
        }
    }

    private func parseOptionalInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
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
