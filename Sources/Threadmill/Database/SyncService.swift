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
            let chatSessions = parseChatSessions(snapshotResult)
            let agentStatus = parseAgentStatusByThread(chatSessions)
            let chatSessionMetadata = parseChatSessionMetadata(chatSessions)
            let presetCount = projects.flatMap(\.presets).count
            Logger.sync.info("Parsed \(projects.count) projects, \(threads.count) threads, \(presetCount) presets — writing to DB")
            try databaseManager.replaceAllFromDaemon(projects: projects, threads: threads, remoteId: remoteId)
            try syncChatSessions(chatSessions)
            Logger.sync.info("DB write done — calling reloadFromDatabase")
            appState.reloadFromDatabase()
            appState.replaceAgentStatus(agentStatus)
            appState.replaceChatSessionMetadata(
                capabilitiesBySessionID: chatSessionMetadata.capabilitiesBySessionID,
                sessionStateBySessionID: chatSessionMetadata.sessionStateBySessionID
            )
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

    private func parseAgentStatusByThread(_ sessions: [[String: Any]]) -> [String: AgentActivityInfo] {

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

    private func parseChatSessions(_ payload: Any) -> [[String: Any]] {
        guard let snapshot = payload as? [String: Any] else {
            return []
        }

        var sessions: [[String: Any]] = []

        if let flatSessions = snapshot["chat_sessions"] as? [[String: Any]] {
            sessions.append(contentsOf: flatSessions)
        }

        if let threadRows = snapshot["threads"] as? [[String: Any]] {
            for threadRow in threadRows {
                guard let threadID = threadRow["id"] as? String,
                      let threadSessions = threadRow["chat_sessions"] as? [[String: Any]]
                else {
                    continue
                }

                for var session in threadSessions {
                    if session["thread_id"] == nil {
                        session["thread_id"] = threadID
                    }
                    sessions.append(session)
                }
            }
        }

        return sessions
    }

    private func parseChatSessionMetadata(_ sessions: [[String: Any]]) -> (
        capabilitiesBySessionID: [String: ChatSessionCapabilities],
        sessionStateBySessionID: [String: ChatSessionState]
    ) {
        var capabilitiesBySessionID: [String: ChatSessionCapabilities] = [:]
        var sessionStateBySessionID: [String: ChatSessionState] = [:]

        for session in sessions {
            guard let sessionID = session["session_id"] as? String else {
                continue
            }

            if let capabilities = sessionCapabilities(from: session) {
                capabilitiesBySessionID[sessionID] = capabilities
            }

            sessionStateBySessionID[sessionID] = sessionState(from: session)
        }

        return (capabilitiesBySessionID, sessionStateBySessionID)
    }

    private func syncChatSessions(_ sessions: [[String: Any]]) throws {
        for session in sessions {
            guard
                let threadID = session["thread_id"] as? String,
                let sessionID = session["session_id"] as? String
            else {
                continue
            }

            var conversation = try databaseManager.conversation(threadID: threadID, agentSessionID: sessionID)
                ?? ChatConversation(
                    id: UUID().uuidString,
                    threadID: threadID,
                    agentSessionID: sessionID,
                    agentType: session["agent_type"] as? String ?? "opencode",
                    title: session["title"] as? String ?? "",
                    status: sessionStatus(from: session),
                    modelID: sessionModelID(from: session),
                    createdAt: parseDate(session["created_at"]) ?? Date(),
                    updatedAt: parseDate(session["updated_at"]),
                    isArchived: false
                )

            conversation.agentSessionID = sessionID
            conversation.agentType = session["agent_type"] as? String ?? conversation.agentType

            if let title = session["title"] as? String {
                conversation.title = title
            }

            conversation.status = sessionStatus(from: session)
            if let modelID = sessionModelID(from: session) {
                conversation.modelID = modelID
            }

            if conversation.status == "ended" {
                conversation.isArchived = true
            }

            conversation.updatedAt = Date()
            try databaseManager.saveConversation(conversation)
        }
    }

    private func sessionStatus(from session: [String: Any]) -> String {
        if let status = session["status"] as? String {
            return status
        }
        return "starting"
    }

    private func sessionState(from session: [String: Any]) -> ChatSessionState {
        switch sessionStatus(from: session).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ready":
            return .ready
        case "failed":
            let message = (session["error"] as? String) ?? "Session failed."
            return .failed(ChatSessionStateError(message: message))
        case "ended":
            return .failed(ChatSessionStateError(message: "Session ended."))
        default:
            return .starting
        }
    }

    private func sessionCapabilities(from session: [String: Any]) -> ChatSessionCapabilities? {
        var hydrated = decodeChatCapabilities(from: session["capabilities"])

        if let modelID = sessionModelID(from: session) {
            if hydrated == nil {
                hydrated = ChatSessionCapabilities()
            }

            if hydrated?.currentModelID == nil {
                hydrated = ChatSessionCapabilities(
                    modes: hydrated?.modes ?? [],
                    models: hydrated?.models ?? [],
                    currentModeID: hydrated?.currentModeID,
                    currentModelID: modelID
                )
            }

            if hydrated?.models.contains(where: { $0.id == modelID }) == false {
                hydrated = ChatSessionCapabilities(
                    modes: hydrated?.modes ?? [],
                    models: (hydrated?.models ?? []) + [ChatModelCapability(id: modelID)],
                    currentModeID: hydrated?.currentModeID,
                    currentModelID: hydrated?.currentModelID
                )
            }
        }

        return hydrated
    }

    private func decodeChatCapabilities(from payload: Any?) -> ChatSessionCapabilities? {
        guard let payload else {
            return nil
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload)
        else {
            return nil
        }

        return try? JSONDecoder().decode(ChatSessionCapabilities.self, from: data)
    }

    private func sessionModelID(from payload: [String: Any]) -> String? {
        if let modelID = payload["model_id"] as? String {
            return modelID
        }

        if let models = payload["models"] as? [String: Any] {
            if let current = models["currentModelId"] as? String {
                return current
            }
            if let current = models["current_model_id"] as? String {
                return current
            }
        }

        if let capabilities = payload["capabilities"] as? [String: Any],
           let models = capabilities["models"] as? [String: Any]
        {
            if let current = models["currentModelId"] as? String {
                return current
            }
            if let current = models["current_model_id"] as? String {
                return current
            }
        }

        return nil
    }
}
