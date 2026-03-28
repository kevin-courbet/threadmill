import Foundation
import os

@MainActor
final class SyncService: SyncServicing {
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
            Logger.sync.info("syncFromDaemon START")
            let projectsResult = try await connectionManager.request(method: "project.list", params: nil, timeout: 10)
            let threadsResult = try await connectionManager.request(method: "thread.list", params: [:], timeout: 10)
            let snapshotResult = try await connectionManager.request(method: "state.snapshot", params: nil, timeout: 10)

            let projects = parseProjects(projectsResult)
            let threads = parseThreads(threadsResult)
            let agentStatus = parseAgentStatusByThread(snapshotResult)
            let presetCount = projects.flatMap(\.presets).count
            Logger.sync.info("Parsed \(projects.count) projects, \(threads.count) threads, \(presetCount) presets — writing to DB")
            try databaseManager.replaceAllFromDaemon(projects: projects, threads: threads, remoteId: remoteId)
            Logger.sync.info("DB write done — calling reloadFromDatabase")
            appState.reloadFromDatabase()
            appState.replaceAgentStatus(agentStatus)
            Logger.sync.info("syncFromDaemon DONE — appState.presets.count=\(self.appState.presets.count)")
        } catch {
            Logger.sync.error("Sync failed: \(error)")
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
            let presets = parsePresetConfigs(row["presets"])
            let agents = parseAgentConfigs(row["agents"])
            return Project(
                id: id,
                name: name,
                remotePath: remotePath,
                defaultBranch: defaultBranch,
                presets: presets,
                agents: agents,
                remoteId: row["remote_id"] as? String ?? row["remoteId"] as? String,
                repoId: row["repo_id"] as? String ?? row["repoId"] as? String
            )
        }
    }

    private func parseAgentConfigs(_ payload: Any?) -> [AgentConfig] {
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

            return AgentConfig(name: name, command: command, cwd: row["cwd"] as? String)
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

    private func parseAgentStatusByThread(_ payload: Any) -> [String: AgentActivityInfo] {
        guard
            let snapshot = payload as? [String: Any],
            let sessions = snapshot["chat_sessions"] as? [[String: Any]]
        else {
            return [:]
        }

        var statuses: [String: AgentActivityInfo] = [:]

        for session in sessions {
            guard
                let threadID = session["thread_id"] as? String,
                let statusPayload = session["agent_status"] as? [String: Any],
                let statusValue = statusPayload["status"] as? String
            else {
                continue
            }

            let workerCount = parseOptionalInt(statusPayload["worker_count"] ?? statusPayload["workerCount"]) ?? 0
            let lastUpdate = parseDate(statusPayload["last_update_time"] ?? statusPayload["lastUpdateTime"]) ?? Date()

            statuses[threadID] = AgentActivityInfo.from(
                rawStatus: statusValue,
                workerCount: workerCount,
                lastUpdateTime: lastUpdate
            )
        }

        return statuses
    }
}
