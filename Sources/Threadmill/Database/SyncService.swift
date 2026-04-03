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

            let projects = parseProjects(projectsResult)
            let threads = parseThreads(threadsResult)
            let presetCount = projects.flatMap(\.presets).count
            Logger.sync.info("Parsed \(projects.count) projects, \(threads.count) threads, \(presetCount) presets — writing to DB")
            try databaseManager.replaceAllFromDaemon(projects: projects, threads: threads, remoteId: remoteId)
            Logger.sync.info("DB write done — calling reloadFromDatabase")
            appState.reloadFromDatabase()

            await syncAgentRegistry()

            Logger.sync.info("syncFromDaemon DONE — appState.presets.count=\(self.appState.presets.count)")
        } catch {
            Logger.sync.error("Sync failed: \(error)")
        }
    }

    func syncAgentRegistry() async {
        do {
            let result = try await connectionManager.request(method: "agent.registry.list", params: [:], timeout: 10)
            let entries = parseAgentRegistry(result)
            appState.agentRegistry = entries
            Logger.sync.info("Agent registry synced — \(entries.count) agents, \(entries.filter(\.installed).count) installed")
        } catch {
            Logger.sync.error("Agent registry sync failed: \(error)")
        }
    }

    private func parseAgentRegistry(_ payload: Any) -> [AgentRegistryEntry] {
        guard let rows = payload as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard
                let id = row["id"] as? String,
                let name = row["name"] as? String,
                let command = row["command"] as? String
            else {
                return nil
            }

            let launchArgs = (row["launch_args"] as? [String]) ?? []
            let installed = (row["installed"] as? Bool) ?? false
            let resolvedPath = row["resolved_path"] as? String

            var installMethod: AgentInstallMethod?
            if let methodDict = row["install_method"] as? [String: Any],
               let type = methodDict["type"] as? String,
               let package = methodDict["package"] as? String
            {
                switch type {
                case "npm":
                    installMethod = .npm(package: package)
                case "uv":
                    installMethod = .uv(package: package)
                default:
                    break
                }
            }

            return AgentRegistryEntry(
                id: id,
                name: name,
                command: command,
                launchArgs: launchArgs,
                installed: installed,
                resolvedPath: resolvedPath,
                installMethod: installMethod
            )
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
}
