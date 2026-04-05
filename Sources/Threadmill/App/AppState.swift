import AppKit
import Foundation
import Observation
import os

enum AppStateError: LocalizedError {
    case connectionManagerUnavailable
    case connectionNotReady
    case invalidGitStatusResponse
    case invalidProjectResponse
    case defaultWorkspaceProjectAlreadyLinked(projectID: String, repoID: String)
    case provisioningUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionManagerUnavailable:
            "Connection to spindle is unavailable."
        case .connectionNotReady:
            "Connection to spindle is still starting. Try again once it finishes connecting."
        case .invalidGitStatusResponse:
            "Invalid response for file.git_status."
        case .invalidProjectResponse:
            "Invalid response while preparing the project."
        case let .defaultWorkspaceProjectAlreadyLinked(projectID, repoID):
            "Project \(projectID) is already linked to repo \(repoID), refusing to relink as cross-project workspace."
        case .provisioningUnavailable:
            "Provisioning service is unavailable."
        }
    }
}

struct TerminalDebugSnapshot: Codable, Equatable {
    let threadID: String?
    let preset: String
    let connectionStatus: String
    let sessionReady: Bool
    let reconnectAttempt: Int
    let pendingAttach: Bool
    let endpointAttached: Bool
    let endpointChannelID: UInt16?
    let openPresets: [String]
    let connectionLastError: String?
    let lastStartError: String?
    let lastAttachError: String?

    var summary: String {
        let threadDescription = threadID ?? "nil"
        let channelDescription = endpointChannelID.map(String.init) ?? "nil"
        let startErrorDescription = lastStartError ?? "nil"
        let attachErrorDescription = lastAttachError ?? "nil"
        let openPresetDescription = openPresets.joined(separator: ",")
        let connectionDescription = connectionStatus
        let connectionErrorDescription = connectionLastError ?? "nil"

        return [
            "thread=\(threadDescription)",
            "preset=\(preset)",
            "connection=\(connectionDescription)",
            "sessionReady=\(sessionReady)",
            "reconnectAttempt=\(reconnectAttempt)",
            "pendingAttach=\(pendingAttach)",
            "endpointAttached=\(endpointAttached)",
            "channel=\(channelDescription)",
            "openPresets=\(openPresetDescription)",
            "connectionLastError=\(connectionErrorDescription)",
            "lastStartError=\(startErrorDescription)",
            "lastAttachError=\(attachErrorDescription)",
        ].joined(separator: "\n")
    }
}

struct AppStateDebugSnapshot: Codable, Equatable {
    let selectedWorkspaceRemoteID: String?
    let selectedThreadID: String?
    let selectedPreset: String?
    let connection: ConnectionDebugSnapshot
    let terminal: TerminalDebugSnapshot?
    let alertMessage: String?

    var summary: String {
        let workspaceRemoteDescription = selectedWorkspaceRemoteID ?? "nil"
        let threadDescription = selectedThreadID ?? "nil"
        let presetDescription = selectedPreset ?? "nil"
        let alertDescription = alertMessage ?? "nil"
        let terminalSummary = terminal?.summary.replacingOccurrences(of: "\n", with: " | ") ?? "nil"

        return [
            "selectedWorkspaceRemoteID=\(workspaceRemoteDescription)",
            "selectedThreadID=\(threadDescription)",
            "selectedPreset=\(presetDescription)",
            "connection.status=\(connection.status)",
            "connection.sessionReady=\(connection.sessionReady)",
            "connection.reconnectAttempt=\(connection.reconnectAttempt)",
            "connection.lastError=\(connection.lastErrorDescription ?? "nil")",
            "terminal=\(terminalSummary)",
            "alert=\(alertDescription)",
        ].joined(separator: "\n")
    }
}


@MainActor
@Observable
final class AppState {
    private struct AttachmentKey: Hashable {
        let threadID: String
        /// Session identifier. For named presets this equals the preset name.
        /// For terminals this is a unique ID like "terminal-1".
        let sessionID: String

        /// The daemon preset name derived from the session ID.
        var presetName: String {
            Preset.baseName(forSessionID: sessionID)
        }
    }

    var connectionStatus: ConnectionStatus = .disconnected {
        didSet {
            if case .connected = connectionStatus, oldValue != connectionStatus {
                Logger.state.info("connectionStatus → connected (presets=\(self.presets.count), selectedThread=\(self.selectedThreadID ?? "nil", privacy: .public), selectedPreset=\(self.selectedPreset ?? "nil", privacy: .public))")
                let shouldRetry = shouldRetrySelectedPresetAttach()
                Logger.state.info("shouldRetrySelectedPresetAttach=\(shouldRetry)")
                if shouldRetry {
                    scheduleAttachSelectedPreset()
                }
                startStatsTimer()
            } else if connectionStatus == .disconnected {
                Logger.state.info("connectionStatus → disconnected")
                pendingScheduledAttachTask?.cancel()
                pendingScheduledAttachTask = nil
                stopStatsTimer()
                systemStats = nil
                agentStatus.removeAll()
            }
        }
    }
    var remotes: [Remote] = [] {
        didSet {
            rebuildWorkspacePathsByRemoteID()
        }
    }
    var repos: [Repo] = []
    var projects: [Project] = [] {
        didSet {
            rebuildProjectsByID()
        }
    }
    var threads: [ThreadModel] = []
    var chatSessionsByThreadID: [String: [ChatSessionInfo]] = [:]
    var agentStatus: [String: AgentActivityInfo] = [:]
    /// Error messages from chat.session_failed events, keyed by session ID
    var sessionErrors: [String: String] = [:]
    var agentRegistry: [AgentRegistryEntry] = []
    var systemStats: SystemStatsResult?
    var pinnedThreadIDs: Set<String> = {
        guard let data = UserDefaults.standard.data(forKey: "pinnedThreadIDs"),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return ids
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(pinnedThreadIDs) {
                UserDefaults.standard.set(data, forKey: "pinnedThreadIDs")
            }
        }
    }
    private var statsTask: Task<Void, Never>?
    private let statsPollingEnabled: Bool
    private let statsRefreshIntervalNanoseconds: UInt64

    var isNewThreadSheetPresented = false
    var alertMessage: String?
    var selectedWorkspaceRemoteID: String? {
        didSet {
            guard oldValue != selectedWorkspaceRemoteID, selectedThreadID == nil else {
                return
            }
            updateActiveRemoteConnection()
        }
    }
    var selectedThreadID: String? {
        didSet {
            ensureSelectedPresetIsValid()
            refreshSelectedEndpoint()
            updateActiveRemoteConnection()
            if let selectedThreadID {
                UserDefaults.standard.set(selectedThreadID, forKey: "threadmill.last-selected-thread")
            }
        }
    }
    var selectedPreset: String? {
        didSet {
            refreshSelectedEndpoint()
        }
    }
    var selectedEndpoint: RelayEndpoint?
    private(set) var chatConversationService: (any ChatConversationManaging)?
    private(set) var fileService: (any FileBrowsing)?
    private(set) var agentSessionManager: AgentSessionManager?

    private(set) var databaseManager: (any DatabaseManaging)?
    private var notificationService: (any NotificationServicing)?
    private var provisioningService: (any Provisioning)?
    private var syncService: (any SyncServicing)?
    private var multiplexer: (any TerminalMultiplexing)?
    private var connectionPool: (any RemoteConnectionPooling)?
    private var eventSyncScheduled = false
    private var attachedEndpoints: [AttachmentKey: RelayEndpoint] = [:]
    private(set) var pendingScheduledAttachTask: Task<Void, Never>?
    private var pendingScheduledAttachToken = 0
    private var pendingAttachTasks: [AttachmentKey: Task<Void, Never>] = [:]
    private var permanentAttachFailures: Set<AttachmentKey> = []
    private var lastPresetStartErrors: [AttachmentKey: String] = [:]
    private var lastAttachErrors: [AttachmentKey: String] = [:]
    private var workspacePathsByRemoteID: [String: String] = [:]
    private var projectsByID: [String: Project] = [:]
    private let isAppFrontmost: @MainActor () -> Bool

    init(
        statsPollingEnabled: Bool = false,
        statsRefreshInterval: TimeInterval = 5,
        isAppFrontmost: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) {
        self.statsPollingEnabled = statsPollingEnabled
        let refreshInterval = max(statsRefreshInterval, 0.1)
        statsRefreshIntervalNanoseconds = UInt64(refreshInterval * 1_000_000_000)
        self.isAppFrontmost = isAppFrontmost
    }

    private var connectionManager: (any ConnectionManaging)? {
        connectionForSelectedThread() ?? defaultConnectionManager()
    }

    var selectedThread: ThreadModel? {
        threads.first { $0.id == selectedThreadID }
    }

    var selectedProject: Project? {
        guard let projectID = selectedThread?.projectId else {
            return nil
        }
        return projectsByID[projectID]
    }

    var activeRemoteID: String? {
        if let activeRemoteID = connectionPool?.activeRemoteId {
            return activeRemoteID
        }
        return remotes.first?.id
    }

    var defaultWorkspaceRepo: Repo? {
        repos.first(where: \.isDefaultWorkspace)
    }

    private func rebuildWorkspacePathsByRemoteID() {
        workspacePathsByRemoteID = Dictionary(
            remotes.map { remote in
                (remote.id, remote.defaultWorkspacePath.normalizedRemotePath)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func rebuildProjectsByID() {
        projectsByID = Dictionary(
            projects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func isDefaultWorkspaceProject(_ project: Project) -> Bool {
        if project.repoId == Repo.defaultWorkspaceID {
            return true
        }

        if project.repoId != nil {
            return false
        }

        guard let remoteID = project.remoteId,
              let workspacePath = workspacePathsByRemoteID[remoteID]
        else {
            return false
        }

        return project.remotePath.normalizedRemotePath == workspacePath
    }

    func connectionForSelectedThread() -> (any ConnectionManaging)? {
        guard let selectedThreadID else {
            return nil
        }
        return connectionForThread(id: selectedThreadID)
    }

    func togglePin(threadID: String) {
        if pinnedThreadIDs.contains(threadID) {
            pinnedThreadIDs.remove(threadID)
        } else {
            pinnedThreadIDs.insert(threadID)
        }
    }

    var pinnedThreads: [ThreadModel] {
        visibleThreads
            .filter { pinnedThreadIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Visible threads excluding pinned ones (shown in their own section).
    private var unpinnedVisibleThreads: [ThreadModel] {
        visibleThreads.filter { !pinnedThreadIDs.contains($0.id) }
    }

    var projectsWithThreads: [(Project, [ThreadModel])] {
        let grouped = Dictionary(grouping: unpinnedVisibleThreads, by: \.projectId)
        return projects
            .filter { !isDefaultWorkspaceProject($0) && $0.repoId == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { project in
                let rows = (grouped[project.id] ?? []).sorted { $0.createdAt > $1.createdAt }
                return (project, rows)
            }
    }

    var reposWithThreads: [(Repo, [ThreadModel])] {
        let grouped: [String?: [ThreadModel]] = Dictionary(grouping: unpinnedVisibleThreads) { thread -> String? in
            guard let project = projectsByID[thread.projectId] else {
                return nil
            }
            if isDefaultWorkspaceProject(project) {
                return Repo.defaultWorkspaceID
            }
            return project.repoId
        }

        return repos
            .sorted { lhs, rhs in
                if lhs.isDefaultWorkspace != rhs.isDefaultWorkspace {
                    return lhs.isDefaultWorkspace
                }
                return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
            }
            .map { repo in
                let rows = (grouped[repo.id] ?? []).sorted { $0.createdAt > $1.createdAt }
                return (repo, rows)
            }
    }

    var presets: [Preset] {
        guard let selectedProject else {
            return []
        }

        let configuredPresets = selectedProject.presets.map { Preset(name: $0.name) }
        return Preset.orderedByDefaultPriority(configuredPresets)
    }

    var terminalTabs: [TerminalTabModel] {
        guard let thread = selectedThread else {
            return []
        }

        let openPresetNames = openPresetNames(for: thread.id)
        let visiblePresetNames = presets
            .map(\.name)
            .filter { openPresetNames.contains($0) || selectedPreset.map { daemonPresetName(forSessionID: $0) } == $0 }

        let terminalTabs: [TerminalTabModel] = visiblePresetNames.compactMap { presetName in
            guard let preset = presets.first(where: { $0.name == presetName }) else {
                return nil
            }

            return TerminalTabModel(
                threadID: thread.id,
                type: .terminal(preset),
                endpoint: attachedEndpoints[AttachmentKey(threadID: thread.id, sessionID: presetName)]
            )
        }

        return terminalTabs + [
            TerminalTabModel(threadID: thread.id, type: .chat, endpoint: nil)
        ]
    }

    func endpointForSession(threadID: String, sessionID: String) -> RelayEndpoint? {
        attachedEndpoints[AttachmentKey(threadID: threadID, sessionID: sessionID)]
    }

    func terminalDebugSnapshot(for preset: String) -> TerminalDebugSnapshot? {
        guard let thread = selectedThread else {
            return nil
        }

        let key = AttachmentKey(threadID: thread.id, sessionID: preset)
        let endpoint = attachedEndpoints[key]
        let connectionSnapshot = connectionForThread(id: thread.id)?.debugSnapshot

        return TerminalDebugSnapshot(
            threadID: thread.id,
            preset: preset,
            connectionStatus: connectionSnapshot?.status ?? connectionStatus.label,
            sessionReady: connectionSnapshot?.sessionReady ?? false,
            reconnectAttempt: connectionSnapshot?.reconnectAttempt ?? 0,
            pendingAttach: pendingAttachTasks[key] != nil,
            endpointAttached: endpoint != nil,
            endpointChannelID: endpoint?.channelID,
            openPresets: openPresetNames(for: thread.id).sorted(),
            connectionLastError: connectionSnapshot?.lastErrorDescription,
            lastStartError: lastPresetStartErrors[key],
            lastAttachError: lastAttachErrors[key]
        )
    }

    func debugSnapshot() -> AppStateDebugSnapshot {
        let connectionSnapshot = currentConnectionDebugSnapshot()
        let selectedPresetSnapshot: TerminalDebugSnapshot?
        if let selectedPreset, selectedPreset != TerminalTabModel.chatTabSelectionID {
            selectedPresetSnapshot = terminalDebugSnapshot(for: selectedPreset)
        } else {
            selectedPresetSnapshot = nil
        }

        return AppStateDebugSnapshot(
            selectedWorkspaceRemoteID: selectedWorkspaceRemoteID,
            selectedThreadID: selectedThreadID,
            selectedPreset: selectedPreset,
            connection: connectionSnapshot,
            terminal: selectedPresetSnapshot,
            alertMessage: alertMessage
        )
    }

    func configure(
        connectionPool: any RemoteConnectionPooling,
        databaseManager: any DatabaseManaging,
        syncService: any SyncServicing,
        multiplexer: any TerminalMultiplexing,
        provisioningService: (any Provisioning)? = nil,
        chatConversationService: (any ChatConversationManaging)? = nil,
        fileService: (any FileBrowsing)? = nil,
        agentSessionManager: AgentSessionManager? = nil,
        notificationService: (any NotificationServicing)? = nil
    ) {
        self.connectionPool = connectionPool
        self.databaseManager = databaseManager
        self.provisioningService = provisioningService ?? ProvisioningService(connectionPool: connectionPool)
        self.syncService = syncService
        self.multiplexer = multiplexer
        self.chatConversationService = chatConversationService
        self.agentSessionManager = agentSessionManager
        self.notificationService = notificationService
        self.fileService = fileService ?? FileService(connectionProvider: { [weak self] in
            self?.connectionForSelectedThread() ?? self?.defaultConnectionManager()
        })
    }

    func ensureValidSelection() {
        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) {
            return
        }

        // Restore last selected thread from previous session
        if let persisted = UserDefaults.standard.string(forKey: "threadmill.last-selected-thread"),
           threads.contains(where: { $0.id == persisted })
        {
            selectedThreadID = persisted
            return
        }

        selectedThreadID = threads.first?.id
    }

    func reloadFromDatabase() {
        guard let databaseManager else {
            return
        }

        do {
            let previousRemotes = remotes
            remotes = try databaseManager.allRemotes()
            reconcileConnectionPool(previousRemotes: previousRemotes, currentRemotes: remotes)
            repos = try databaseManager.allRepos()
            injectDefaultWorkspaceRepo()
            projects = try databaseManager.allProjects()
            normalizeDefaultWorkspaceProjects()
            threads = try databaseManager.allThreads()
            Logger.state.info("reloadFromDatabase — projects=\(self.projects.count), threads=\(self.threads.count), presets=\(self.presets.count), selectedThread=\(self.selectedThreadID ?? "nil", privacy: .public), selectedPreset=\(self.selectedPreset ?? "nil", privacy: .public), connected=\(self.connectionStatus.isConnected)")
            if selectedWorkspaceRemoteID == nil {
                selectedWorkspaceRemoteID = remotes.first?.id
            }
            pruneDetachedThreadEndpoints()
            ensureValidSelection()
            ensureSelectedPresetIsValid()
            refreshSelectedEndpoint()
            updateActiveRemoteConnection()
            let shouldRetry = shouldRetrySelectedPresetAttach()
            Logger.state.info("post-reload: presets=\(self.presets.count), shouldRetry=\(shouldRetry)")
            if connectionStatus.isConnected, shouldRetry {
                scheduleAttachSelectedPreset()
            }
        } catch {
            Logger.state.error("Failed to load cache: \(error)")
        }
    }

    private func reconcileConnectionPool(previousRemotes: [Remote], currentRemotes: [Remote]) {
        guard let connectionPool else {
            return
        }

        let previousByID = Dictionary(uniqueKeysWithValues: previousRemotes.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: currentRemotes.map { ($0.id, $0) })

        for remoteID in previousByID.keys where currentByID[remoteID] == nil {
            connectionPool.removeRemote(id: remoteID)
        }

        for remote in currentRemotes {
            if let previousRemote = previousByID[remote.id] {
                if previousRemote != remote {
                    connectionPool.updateRemote(remote)
                }
            } else {
                connectionPool.addRemote(remote)
            }
        }
    }

    func syncNow() async {
        await syncService?.syncFromDaemon()
    }

    func installAgent(agentID: String) async throws -> Bool {
        guard let connectionManager else {
            throw AppStateError.connectionManagerUnavailable
        }
        let result = try await connectionManager.request(
            method: "agent.registry.install",
            params: ["agent_id": agentID],
            timeout: 120
        )
        guard let payload = result as? [String: Any] else {
            return false
        }
        let success = (payload["success"] as? Bool) ?? false
        if success {
            await syncService?.syncAgentRegistry()
        }
        return success
    }

    func handleDaemonEvent(method: String, params: [String: Any]?) {
        switch method {
        case "thread.status_changed":
            handleThreadStatusChanged(params)
        case "thread.progress":
            handleThreadProgress(params)
        case "project.clone_progress":
            handleProjectCloneProgress(params)
        case "chat.status_changed":
            handleChatStatusChanged(params)
         case "chat.session_failed":
            handleChatSessionFailed(params)
        case "chat.session_added":
            handleChatSessionAdded(params)
        case "chat.session_updated":
            handleChatSessionUpdated(params)
        case "chat.session_removed":
            handleChatSessionRemoved(params)
        case "thread.created",
             "thread.removed",
             "project.added",
             "project.removed",
             "state.delta",
             "preset.process_event":
            scheduleEventSync()
        default:
            break
        }
    }

    func scheduleAttachSelectedPreset() {
        let hadPrevious = pendingScheduledAttachTask != nil
        pendingScheduledAttachTask?.cancel()
        pendingScheduledAttachToken += 1
        let token = pendingScheduledAttachToken
        Logger.state.info("scheduleAttachSelectedPreset token=\(token) cancelledPrevious=\(hadPrevious)")
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else {
                Logger.state.info("scheduleAttach token=\(token) — cancelled before execution")
                return
            }
            defer {
                if let self, self.pendingScheduledAttachToken == token {
                    self.pendingScheduledAttachTask = nil
                }
            }
            await self?.attachSelectedPreset()
        }
        pendingScheduledAttachTask = task
    }

    func attachSelectedPreset() async {
        Logger.state.info("attachSelectedPreset START — selectedThread=\(self.selectedThread?.id ?? "nil", privacy: .public), selectedPreset=\(self.selectedPreset ?? "nil", privacy: .public), presets=\(self.presets.count)")
        guard let selectedThread else {
            Logger.state.info("attachSelectedPreset BAIL — no selectedThread")
            cancelPendingAttachTasks()
            selectedEndpoint = nil
            return
        }

        if selectedPreset == TerminalTabModel.chatTabSelectionID {
            Logger.state.info("attachSelectedPreset BAIL — chat mode selected")
            cancelPendingAttachTasks(threadID: selectedThread.id)
            selectedEndpoint = nil
            return
        }

        guard let preset = selectedPreset ?? selectedTerminalSessionIDToRecover(threadID: selectedThread.id) ?? presets.first?.name else {
            Logger.state.info("attachSelectedPreset BAIL — no preset resolved (selectedPreset=nil, recover=nil, presets.first=nil)")
            selectedEndpoint = nil
            return
        }

        let availablePresetNames = Set(presets.map(\.name))
        let normalizedPreset = daemonPresetName(forSessionID: preset)
        Logger.state.info("attachSelectedPreset preset=\(preset, privacy: .public), normalized=\(normalizedPreset, privacy: .public), available=\(availablePresetNames.joined(separator: ","), privacy: .public)")
        guard availablePresetNames.contains(normalizedPreset) else {
            Logger.state.info("attachSelectedPreset BAIL — normalized preset '\(normalizedPreset, privacy: .public)' not in available presets")
            selectedPreset = presets.first?.name
            selectedEndpoint = nil
            return
        }

        await attachPreset(threadID: selectedThread.id, preset: preset)
    }

    /// Attach to a terminal session. sessionID is the local tab identifier
    /// (e.g. "terminal-1", "dev-server"). The daemon preset name is derived from it.
    func attachPreset(threadID: String, preset sessionID: String) async {
        Logger.state.info("attachPreset(thread=\(threadID, privacy: .public), session=\(sessionID, privacy: .public)) presets=\(self.presets.count)")
        guard selectedThreadID == threadID else {
            Logger.state.info("attachPreset BAIL — selectedThreadID=\(self.selectedThreadID ?? "nil", privacy: .public) != threadID=\(threadID, privacy: .public)")
            return
        }

        let daemonPreset = Preset.baseName(forSessionID: sessionID)
        guard presets.contains(where: { $0.name == daemonPreset }) else {
            Logger.state.info("attachPreset BAIL — daemon preset '\(daemonPreset, privacy: .public)' not in presets [\(self.presets.map(\.name).joined(separator: ","), privacy: .public)]")
            selectedPreset = presets.first?.name
            selectedEndpoint = nil
            return
        }

        selectedPreset = sessionID

        let key = AttachmentKey(threadID: threadID, sessionID: sessionID)

        guard canAttemptAttach(threadID: threadID, key: key) else {
            cancelPendingAttachTasks(threadID: threadID)
            selectedEndpoint = attachedEndpoints[key]
            return
        }

        if let existingTask = pendingAttachTasks[key] {
            await existingTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer { self.pendingAttachTasks.removeValue(forKey: key) }
            await self.performAttachPreset(threadID: threadID, key: key)
        }
        pendingAttachTasks[key] = task
        await task.value
    }

    func startPreset(named preset: String) async {
        guard let threadID = selectedThreadID else {
            return
        }

        await startPreset(threadID: threadID, preset: preset)
    }

    /// Start a preset and attach. sessionID defaults to preset name for named presets.
    func startPreset(threadID: String, preset sessionID: String) async {
        let daemonPreset = Preset.baseName(forSessionID: sessionID)

        guard selectedThreadID == threadID,
              let connectionManager = connectionForThread(id: threadID)
        else {
            return
        }
        guard presets.contains(where: { $0.name == daemonPreset }) else {
            return
        }

        let key = AttachmentKey(threadID: threadID, sessionID: sessionID)

        do {
            _ = try await connectionManager.request(
                method: "preset.start",
                params: [
                    "thread_id": threadID,
                    "preset": daemonPreset,
                    "session_id": sessionID,
                ],
                timeout: 20
            )
            lastPresetStartErrors.removeValue(forKey: key)
        } catch {
            if isPresetAlreadyRunningError(error, preset: sessionID) {
                lastPresetStartErrors[key] = String(describing: error)
                selectedPreset = sessionID
                await attachPreset(threadID: threadID, preset: sessionID)
                return
            }
            lastPresetStartErrors[key] = String(describing: error)
            Logger.state.error("preset.start failed (\(threadID)/\(daemonPreset)): \(error)")
            return
        }

        selectedPreset = sessionID
        await attachPreset(threadID: threadID, preset: sessionID)
    }

    func stopPreset(named preset: String) async {
        guard let threadID = selectedThreadID else {
            return
        }

        await stopPreset(threadID: threadID, preset: preset)
    }

    func stopPreset(threadID: String, preset: String) async {
        if preset == TerminalTabModel.chatTabSelectionID {
            guard selectedThreadID == threadID else {
                return
            }
            selectedPreset = presets.first?.name ?? TerminalTabModel.chatTabSelectionID
            return
        }

        guard selectedThreadID == threadID,
              let connectionManager = connectionForThread(id: threadID)
        else {
            return
        }

        let key = AttachmentKey(threadID: threadID, sessionID: preset)
        let baseName = Preset.baseName(forSessionID: preset)

        do {
            _ = try await connectionManager.request(
                method: "preset.stop",
                params: [
                    "thread_id": threadID,
                    "preset": baseName,
                    "session_id": preset,
                ],
                timeout: 20
            )

            pendingAttachTasks[key]?.cancel()
            pendingAttachTasks.removeValue(forKey: key)
            permanentAttachFailures.remove(key)
            lastPresetStartErrors.removeValue(forKey: key)
            lastAttachErrors.removeValue(forKey: key)

            let wasSelected = selectedPreset == preset
            if wasSelected {
                selectedPreset = nil
            }

            detachEndpoint(threadID: threadID, preset: preset)

            if wasSelected {
                let replacement = openPresetNames(for: threadID).sorted().first
                selectedPreset = replacement
                if replacement == nil {
                    selectedEndpoint = nil
                }
            }
        } catch {
            Logger.state.error("preset.stop failed (\(threadID)/\(preset)): \(error)")
        }
    }

    private func performAttachPreset(threadID requestedThreadID: String, key: AttachmentKey) async {
        let requestedSessionID = key.sessionID
        let baseName = Preset.baseName(forSessionID: requestedSessionID)
        Logger.state.info("performAttachPreset START thread=\(requestedThreadID, privacy: .public) preset=\(baseName, privacy: .public) session=\(requestedSessionID, privacy: .public)")
        guard canAttemptAttach(threadID: requestedThreadID, key: key) else {
            Logger.state.info("performAttachPreset BAIL canAttemptAttach=false")
            if selectedThreadID == requestedThreadID && selectedPreset == requestedSessionID {
                selectedEndpoint = attachedEndpoints[key]
            }
            return
        }

        func selectionMatchesRequest() -> Bool {
            selectedThreadID == requestedThreadID && selectedPreset == requestedSessionID
        }

        guard selectionMatchesRequest() else {
            Logger.state.info("performAttachPreset BAIL selectionMatchesRequest=false (selectedThread=\(self.selectedThreadID ?? "nil", privacy: .public) selectedPreset=\(self.selectedPreset ?? "nil", privacy: .public))")
            return
        }

        guard let connectionManager = connectionForThread(id: requestedThreadID), let multiplexer else {
            Logger.state.info("performAttachPreset BAIL no connectionManager or multiplexer")
            return
        }

        if let endpoint = attachedEndpoints[key] {
            Logger.state.info("performAttachPreset existing endpoint found, channel=\(endpoint.channelID)")
            guard selectionMatchesRequest() else {
                return
            }
            selectedEndpoint = endpoint
            if endpoint.channelID == 0, connectionManager.state.isConnected {
                do {
                    let reattachedEndpoint = try await multiplexer.attach(
                        threadID: requestedThreadID,
                        sessionID: requestedSessionID,
                        preset: baseName
                    )
                    guard selectionMatchesRequest(), canAttemptAttach(threadID: requestedThreadID, key: key) else {
                        return
                    }

                    attachedEndpoints[key] = reattachedEndpoint
                    selectedEndpoint = reattachedEndpoint
                } catch {
                    handleAttachError(error, key: key, threadID: requestedThreadID)
                    Logger.state.error("Reattach failed: \(error)")
                }
            }
            return
        }

        do {
            do {
                _ = try await connectionManager.request(
                    method: "preset.start",
                    params: [
                        "thread_id": requestedThreadID,
                        "preset": baseName,
                        "session_id": requestedSessionID,
                    ],
                    timeout: 20
                )
            } catch {
                if !isPresetAlreadyRunningError(error, preset: requestedSessionID) {
                    throw error
                }
            }
            guard selectionMatchesRequest(), canAttemptAttach(threadID: requestedThreadID, key: key) else {
                return
            }

            let endpoint = try await multiplexer.attach(
                threadID: requestedThreadID,
                sessionID: requestedSessionID,
                preset: baseName
            )
            guard selectionMatchesRequest(), canAttemptAttach(threadID: requestedThreadID, key: key) else {
                return
            }

            attachedEndpoints[key] = endpoint
            lastAttachErrors.removeValue(forKey: key)
            selectedEndpoint = endpoint
            Logger.state.info("performAttachPreset SUCCESS endpoint channel=\(endpoint.channelID)")
        } catch {
            Logger.state.error("performAttachPreset FAILED: \(error)")
            handleAttachError(error, key: key, threadID: requestedThreadID)
            lastAttachErrors[key] = String(describing: error)
            Logger.state.error("Attach failed: \(error)")
        }
    }

    private func isPresetAlreadyRunningError(_ error: Error, preset: String) -> Bool {
        guard let rpcError = error as? JSONRPCErrorResponse else {
            return false
        }

        return rpcError.message.contains("preset already running") && rpcError.message.contains(preset)
    }

    func detachCurrentTerminal() async {
        guard
            let thread = selectedThread,
            let preset = selectedPreset
        else {
            selectedEndpoint = nil
            return
        }

        detachEndpoint(threadID: thread.id, preset: preset)
    }

    func hideThread(threadID: String) async {
        guard let connectionManager = connectionForThread(id: threadID) else {
            return
        }
        detachEndpoints(threadID: threadID)

        do {
            _ = try await connectionManager.request(
                method: "thread.hide",
                params: ["thread_id": threadID],
                timeout: 15
            )
            await syncService?.syncFromDaemon()
        } catch {
            Logger.state.error("thread.hide failed (\(threadID)): \(error)")
        }
    }

    func closeThread(threadID: String) async {
        guard let connectionManager = connectionForThread(id: threadID) else {
            return
        }
        detachEndpoints(threadID: threadID)

        do {
            _ = try await connectionManager.request(
                method: "thread.close",
                params: [
                    "thread_id": threadID,
                    "mode": "close",
                ],
                timeout: 15
            )
            await syncService?.syncFromDaemon()
        } catch {
            Logger.state.error("thread.close failed (\(threadID)): \(error)")
        }
    }

    func cancelThreadCreation(threadID: String) async {
        guard let connectionManager = connectionForThread(id: threadID) else {
            return
        }

        do {
            _ = try await connectionManager.request(
                method: "thread.cancel",
                params: ["thread_id": threadID],
                timeout: 15
            )
            await syncService?.syncFromDaemon()
        } catch {
            Logger.state.error("thread.cancel failed (\(threadID)): \(error)")
        }
    }

    func projectId(for repo: Repo, on remote: Remote) -> String? {
        projects.first { project in
            project.repoId == repo.id && project.remoteId == remote.id
        }?.id
    }

    func lookupProject(path: String, on remoteId: String) async throws -> (exists: Bool, isGitRepo: Bool, projectId: String?) {
        guard let provisioningService else {
            throw AppStateError.provisioningUnavailable
        }
        return try await provisioningService.lookupProject(path: path, on: remoteId)
    }

    func ensureRepoOnRemote(repo: Repo, remote: Remote) async throws -> String {
        guard let provisioningService else {
            throw AppStateError.provisioningUnavailable
        }

        let projectID = try await provisioningService.ensureRepoOnRemote(repo: repo, remote: remote)
        linkProject(
            projectID: projectID,
            repoID: repo.id,
            remoteID: remote.id,
            projectName: repo.name,
            remotePath: Remote.joinedRemotePath(root: remote.cloneRoot, owner: repo.owner, repoName: repo.name),
            defaultBranch: repo.defaultBranch
        )
        return projectID
    }

    func createThread(
        repo: Repo,
        remote: Remote,
        name: String,
        sourceType: String,
        branch: String?,
        prURL: String? = nil
    ) async throws {
        if repo.isDefaultWorkspace {
            let path = remote.defaultWorkspacePath
            let projectID = try await ensureDefaultWorkspaceOnRemote(remote: remote)
            try await createThread(
                projectID: projectID,
                name: name,
                sourceType: "main_checkout",
                branch: branch,
                prURL: prURL
            )
            linkProject(
                projectID: projectID,
                repoID: Repo.defaultWorkspaceID,
                remoteID: remote.id,
                projectName: Repo.defaultWorkspace.name,
                remotePath: path,
                defaultBranch: Repo.defaultWorkspace.defaultBranch
            )
            return
        }

        let projectID = try await ensureRepoOnRemote(repo: repo, remote: remote)
        try await createThread(
            projectID: projectID,
            name: name,
            sourceType: sourceType,
            branch: branch,
            prURL: prURL
        )
    }

    func reopenThread(threadID: String) async {
        guard let connectionManager = connectionForThread(id: threadID) else {
            return
        }
        do {
            _ = try await connectionManager.request(
                method: "thread.reopen",
                params: ["thread_id": threadID],
                timeout: 15
            )
            await syncService?.syncFromDaemon()
        } catch {
            Logger.state.error("thread.reopen failed (\(threadID)): \(error)")
        }
    }

    func gitStatus(path: String) async throws -> [String: FileGitStatus] {
        guard let connectionManager else {
            throw AppStateError.connectionManagerUnavailable
        }

        let result = try await connectionManager.request(
            method: "file.git_status",
            params: ["path": path],
            timeout: 20
        )

        guard
            let payload = result as? [String: Any],
            let entries = payload["entries"] as? [String: String]
        else {
            throw AppStateError.invalidGitStatusResponse
        }

        var parsed: [String: FileGitStatus] = [:]
        for (key, value) in entries {
            guard let status = FileGitStatus(rawValue: value) else {
                continue
            }
            parsed[key] = status
        }
        return parsed
    }

    func addProject(path: String) async throws {
        guard let connectionManager else {
            return
        }

        _ = try await connectionManager.request(
            method: "project.add",
            params: ["path": path],
            timeout: 20
        )
        await syncService?.syncFromDaemon()
    }

    func removeProject(projectID: String) async {
        guard let connectionManager = connectionForProject(id: projectID) else { return }
        do {
            _ = try await connectionManager.request(
                method: "project.remove",
                params: ["project_id": projectID],
                timeout: 15
            )
            await syncService?.syncFromDaemon()
        } catch {
            Logger.state.error("project.remove failed (\(projectID)): \(error)")
        }
    }

    func cloneRepo(url: String, path: String?) async throws {
        guard let connectionManager else {
            return
        }

        var params: [String: Any] = ["url": url]
        if let path {
            params["path"] = path
        }

        _ = try await connectionManager.request(
            method: "project.clone",
            params: params,
            timeout: 120
        )
        await syncService?.syncFromDaemon()
    }

    func branches(for projectID: String) async throws -> [String] {
        guard let connectionManager = connectionForProject(id: projectID) else {
            return []
        }

        let result = try await connectionManager.request(
            method: "project.branches",
            params: ["project_id": projectID],
            timeout: 10
        )
        return result as? [String] ?? []
    }

    func createThread(
        projectID: String,
        name: String,
        sourceType: String,
        branch: String?,
        prURL: String? = nil
    ) async throws {
        Logger.state.info("createThread start project=\(projectID, privacy: .public) name=\(name, privacy: .public) source=\(sourceType, privacy: .public) branch=\(branch ?? "<nil>", privacy: .public) pr_url=\(prURL ?? "<nil>", privacy: .public)")

        guard let connectionManager = connectionForProject(id: projectID) else {
            Logger.state.error("createThread aborted, connection manager unavailable")
            throw AppStateError.connectionManagerUnavailable
        }
        guard connectionManager.state == .connected else {
            Logger.state.error("createThread aborted, connection not ready")
            throw AppStateError.connectionNotReady
        }

        var params: [String: Any] = [
            "project_id": projectID,
            "name": name,
            "source_type": sourceType,
        ]

        if let branch, !branch.isEmpty {
            params["branch"] = branch
        }

        if let prURL {
            params["pr_url"] = prURL
        }

        do {
            _ = try await connectionManager.request(method: "thread.create", params: params, timeout: 30)
            Logger.state.info("createThread request sent")
            await syncRemoteState(forProjectID: projectID, using: connectionManager)
            Logger.state.info("createThread sync complete")
        } catch {
            Logger.state.error("createThread failed: \(error)")
            throw error
        }
    }

    private func handleThreadStatusChanged(_ params: [String: Any]?) {
        guard
            let params,
            let threadID = params["thread_id"] as? String,
            let statusRaw = params["new"] as? String,
            let status = ThreadStatus(rawValue: statusRaw)
        else {
            Logger.state.error("Invalid thread.status_changed payload: \(String(describing: params))")
            return
        }

        _ = updateThreadStatus(threadID: threadID, status: status)

        if status == .creating || status == .failed {
            cancelPendingAttachTasks(threadID: threadID)
        }

        if status == .active {
            clearPermanentAttachFailures(threadID: threadID)
            if selectedThreadID == threadID {
                scheduleAttachSelectedPreset()
            }
        }

        if status == .closed || status == .hidden || status == .failed {
            detachEndpoints(threadID: threadID)
        }
    }

    private func handleThreadProgress(_ params: [String: Any]?) {
        guard let params else {
            Logger.state.error("thread.progress payload missing")
            return
        }

        let threadID = params["thread_id"] as? String ?? "unknown"
        let step = params["step"] as? String ?? "unknown"
        let message = params["message"] as? String ?? ""
        let errorText = params["error"] as? String

        if threadID != "unknown", threads.first(where: { $0.id == threadID }) == nil {
            scheduleEventSync()
        }

        if threadID != "unknown", threadProgressIndicatesFailure(step: step, errorText: errorText) {
            _ = updateThreadStatus(threadID: threadID, status: .failed)
            cancelPendingAttachTasks(threadID: threadID)
            detachEndpoints(threadID: threadID)
        }

        if let errorText, !errorText.isEmpty {
            Logger.state.error("thread.progress thread=\(threadID, privacy: .public) step=\(step, privacy: .public) message=\(message, privacy: .public) error=\(errorText)")
        } else {
            Logger.state.info("thread.progress thread=\(threadID, privacy: .public) step=\(step, privacy: .public) message=\(message, privacy: .public)")
        }
    }

    private func handleProjectCloneProgress(_ params: [String: Any]?) {
        guard let params else {
            Logger.state.error("project.clone_progress payload missing")
            return
        }

        let cloneID = params["thread_id"] as? String ?? "unknown"
        let step = params["step"] as? String ?? "unknown"
        let message = params["message"] as? String ?? ""
        let errorText = params["error"] as? String

        if let errorText, !errorText.isEmpty {
            Logger.state.error("project.clone_progress clone=\(cloneID, privacy: .public) step=\(step, privacy: .public) message=\(message, privacy: .public) error=\(errorText)")
        } else {
            Logger.state.info("project.clone_progress clone=\(cloneID, privacy: .public) step=\(step, privacy: .public) message=\(message, privacy: .public)")
        }
    }

    func updateChatSessionsFromSnapshot(_ sessions: [ChatSessionInfo]) {
        chatSessionsByThreadID = Dictionary(grouping: sessions, by: \.threadID)
        recalculateAllAgentStatuses(timestamp: Date())
    }

    private func handleChatStatusChanged(_ params: [String: Any]?) {
        guard
            let params,
            let threadID = params["thread_id"] as? String,
            let sessionID = params["session_id"] as? String,
            let newStatus = params["new_status"] as? String
        else {
            Logger.state.error("Invalid chat.status_changed payload: \(String(describing: params))")
            return
        }

        let previousThreadStatus = agentStatus[threadID]?.status
        let workerCount = parseOptionalInt(params["worker_count"]) ?? 0
        if let status = AgentStatus.fromDaemonStatus(newStatus, workerCount: workerCount) {
            agentStatus[threadID] = AgentActivityInfo(
                status: status,
                workerCount: workerCount,
                lastUpdateTime: Date()
            )
        } else {
            Logger.state.error("Unknown chat status '\(newStatus, privacy: .public)' for thread \(threadID, privacy: .public)")
        }

        updateChatSessionStatus(threadID: threadID, sessionID: sessionID, status: newStatus, workerCount: workerCount)
        notifyIfAgentFinished(threadID: threadID, previousStatus: previousThreadStatus)
    }

    private func notifyIfAgentFinished(threadID: String, previousStatus: AgentStatus?) {
        guard let previousStatus, previousStatus.isBusyOrStalled else {
            return
        }
        guard let currentStatus = agentStatus[threadID]?.status, currentStatus == .idle else {
            return
        }
        guard connectionStatus.isConnected else {
            return
        }
        guard !(isAppFrontmost() && selectedThreadID == threadID) else {
            return
        }

        let threadName = threads.first(where: { $0.id == threadID })?.name ?? threadID
        let projectName = threads
            .first(where: { $0.id == threadID })
            .flatMap { projectsByID[$0.projectId]?.name }
        notificationService?.notifyAgentFinished(threadName: threadName, projectName: projectName)
    }

    private func handleChatSessionFailed(_ params: [String: Any]?) {
        guard
            let params,
            let sessionID = params["session_id"] as? String,
            let error = params["error"] as? String
        else {
            Logger.state.error("Invalid chat.session_failed payload: \(String(describing: params))")
            return
        }
        Logger.state.error("chat.session_failed — sessionID=\(sessionID, privacy: .public), error=\(error, privacy: .public)")
        sessionErrors[sessionID] = error
        agentSessionManager?.recordSessionFailure(sessionID: sessionID, error: error)
    }

    private func handleChatSessionAdded(_ params: [String: Any]?) {
        guard let session = parseChatSession(from: params) else {
            Logger.state.error("Invalid chat.session_added payload: \(String(describing: params))")
            return
        }
        upsertChatSession(session)
    }

    private func handleChatSessionUpdated(_ params: [String: Any]?) {
        guard let session = parseChatSession(from: params) else {
            Logger.state.error("Invalid chat.session_updated payload: \(String(describing: params))")
            return
        }
        upsertChatSession(session)
    }

    private func handleChatSessionRemoved(_ params: [String: Any]?) {
        guard let params else {
            Logger.state.error("chat.session_removed payload missing")
            return
        }

        if let session = parseChatSession(from: params) {
            removeChatSession(threadID: session.threadID, sessionID: session.sessionID)
            return
        }

        guard
            let threadID = params["thread_id"] as? String,
            let sessionID = params["session_id"] as? String
        else {
            Logger.state.error("Invalid chat.session_removed payload: \(String(describing: params))")
            return
        }

        removeChatSession(threadID: threadID, sessionID: sessionID)
    }

    private func parseChatSession(from params: [String: Any]?) -> ChatSessionInfo? {
        guard let params else {
            return nil
        }
        if let nested = params["session"] as? [String: Any] {
            return ChatSessionInfo(payload: nested)
        }
        return ChatSessionInfo(payload: params)
    }

    private func upsertChatSession(_ session: ChatSessionInfo) {
        var sessions = chatSessionsByThreadID[session.threadID] ?? []
        if let index = sessions.firstIndex(where: { $0.sessionID == session.sessionID }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        chatSessionsByThreadID[session.threadID] = sessions
        recalculateAgentStatus(for: session.threadID, timestamp: Date())
    }

    private func updateChatSessionStatus(threadID: String, sessionID: String, status: String, workerCount: Int) {
        guard var sessions = chatSessionsByThreadID[threadID],
              let index = sessions.firstIndex(where: { $0.sessionID == sessionID })
        else {
            return
        }

        sessions[index].applyStatusUpdate(status: status, workerCount: workerCount)
        chatSessionsByThreadID[threadID] = sessions
        recalculateAgentStatus(for: threadID, timestamp: Date())
    }

    private func removeChatSession(threadID: String, sessionID: String) {
        guard var sessions = chatSessionsByThreadID[threadID] else {
            agentStatus.removeValue(forKey: threadID)
            return
        }

        sessions.removeAll { $0.sessionID == sessionID }
        if sessions.isEmpty {
            chatSessionsByThreadID.removeValue(forKey: threadID)
            agentStatus.removeValue(forKey: threadID)
            return
        }

        chatSessionsByThreadID[threadID] = sessions
        recalculateAgentStatus(for: threadID, timestamp: Date())
    }

    private func recalculateAllAgentStatuses(timestamp: Date) {
        var recalculated: [String: AgentActivityInfo] = [:]
        for threadID in chatSessionsByThreadID.keys {
            if let status = aggregateAgentActivity(for: threadID, timestamp: timestamp) {
                recalculated[threadID] = status
            }
        }
        agentStatus = recalculated
    }

    private func recalculateAgentStatus(for threadID: String, timestamp: Date) {
        if let status = aggregateAgentActivity(for: threadID, timestamp: timestamp) {
            agentStatus[threadID] = status
        } else {
            agentStatus.removeValue(forKey: threadID)
        }
    }

    private func aggregateAgentActivity(for threadID: String, timestamp: Date) -> AgentActivityInfo? {
        guard let sessions = chatSessionsByThreadID[threadID], !sessions.isEmpty else {
            return nil
        }

        let statuses = sessions.compactMap(\.agentStatus)
        guard !statuses.isEmpty else {
            return nil
        }

        let workerCount = max(sessions.map(\.workerCount).max() ?? 0, 0)
        let status: AgentStatus
        if statuses.contains(where: {
            if case .stalled = $0 {
                return true
            }
            return false
        }) {
            status = .stalled(workerCount: workerCount)
        } else if statuses.contains(where: {
            if case .busy = $0 {
                return true
            }
            return false
        }) {
            status = .busy(workerCount: workerCount)
        } else {
            status = .idle
        }

        return AgentActivityInfo(status: status, workerCount: workerCount, lastUpdateTime: timestamp)
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

    private func threadProgressIndicatesFailure(step: String, errorText: String?) -> Bool {
        if let errorText {
            let trimmedError = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedError.isEmpty {
                return true
            }
        }

        let normalizedStep = step.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedStep.contains("fail")
    }

    @discardableResult
    private func updateThreadStatus(threadID: String, status: ThreadStatus) -> Bool {
        let hasLocalRow = threads.contains(where: { $0.id == threadID })
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].status = status
        }

        do {
            let persisted = try databaseManager?.updateThreadStatus(threadID: threadID, status: status) ?? false
            if !hasLocalRow || !persisted {
                scheduleEventSync()
            }
            return hasLocalRow || persisted
        } catch {
            Logger.state.error("Failed to persist thread status (\(threadID)): \(error)")
            scheduleEventSync()
            return hasLocalRow
        }
    }

    private func scheduleEventSync() {
        guard !eventSyncScheduled else {
            return
        }
        eventSyncScheduled = true

        Task { @MainActor [weak self] in
            defer { self?.eventSyncScheduled = false }
            await self?.syncService?.syncFromDaemon()
        }
    }

    private func canAttemptAttach(threadID: String, key: AttachmentKey) -> Bool {
        guard !permanentAttachFailures.contains(key) else {
            return false
        }
        guard let status = threads.first(where: { $0.id == threadID })?.status else {
            return false
        }
        return status != .creating && status != .failed
    }

    private func handleAttachError(_ error: Error, key: AttachmentKey, threadID: String) {
        lastAttachErrors[key] = String(describing: error)
        guard isPermanentTerminalAttachError(error) else {
            return
        }
        permanentAttachFailures.insert(key)
        cancelPendingAttachTasks(threadID: threadID)
        detachEndpoint(threadID: threadID, preset: key.sessionID)
    }

    private func isPermanentTerminalAttachError(_ error: Error) -> Bool {
        if let rpcError = error as? JSONRPCErrorResponse {
            return rpcError.message.localizedCaseInsensitiveContains("tmux session not running")
        }
        return String(describing: error).localizedCaseInsensitiveContains("tmux session not running")
    }

    private func clearPermanentAttachFailures(threadID: String) {
        let staleKeys = permanentAttachFailures.filter { $0.threadID == threadID }
        for key in staleKeys {
            permanentAttachFailures.remove(key)
        }
    }

    private func cancelPendingAttachTasks(threadID: String? = nil, except keepKey: AttachmentKey? = nil) {
        let keys = pendingAttachTasks.keys.filter { key in
            if let keepKey, keepKey == key {
                return false
            }
            if let threadID, key.threadID != threadID {
                return false
            }
            return true
        }
        for key in keys {
            pendingAttachTasks[key]?.cancel()
            pendingAttachTasks.removeValue(forKey: key)
        }
    }

    private func refreshSelectedEndpoint() {
        guard
            let threadID = selectedThreadID,
            let preset = selectedPreset,
            preset != TerminalTabModel.chatTabSelectionID
        else {
            selectedEndpoint = nil
            return
        }

        selectedEndpoint = attachedEndpoints[AttachmentKey(threadID: threadID, sessionID: preset)]
    }

    private func ensureSelectedPresetIsValid() {
        let availablePresets = presets.map(\.name)
        guard !availablePresets.isEmpty else {
            selectedPreset = TerminalTabModel.chatTabSelectionID
            return
        }

        if selectedPreset == TerminalTabModel.chatTabSelectionID {
            return
        }

        if let selectedPreset, availablePresets.contains(daemonPresetName(forSessionID: selectedPreset)) {
            return
        }

        selectedPreset = availablePresets[0]
    }

    private func shouldRetrySelectedPresetAttach() -> Bool {
        guard let selectedThreadID else {
            return false
        }
        guard ThreadTabStateManager().selectedMode(threadID: selectedThreadID) == TabItem.terminal.id else {
            return false
        }
        if let selectedPreset {
            return selectedPreset != TerminalTabModel.chatTabSelectionID
        }
        return selectedTerminalSessionIDToRecover(threadID: selectedThreadID) != nil
    }

    private func selectedTerminalSessionIDToRecover(threadID: String) -> String? {
        ThreadTabStateManager().selectedSessionID(modeID: TabItem.terminal.id, threadID: threadID)
    }

    private func daemonPresetName(forSessionID sessionID: String) -> String {
        Preset.baseName(forSessionID: sessionID)
    }

    private func openPresetNames(for threadID: String) -> Set<String> {
        Set(attachedEndpoints.keys.filter { $0.threadID == threadID }.map(\.sessionID))
    }

    private func pruneDetachedThreadEndpoints() {
        let validThreadIDs = Set(threads.map(\.id))
        let staleKeys = attachedEndpoints.keys.filter { !validThreadIDs.contains($0.threadID) }
        for key in staleKeys {
            multiplexer?.detach(threadID: key.threadID, sessionID: key.sessionID)
            attachedEndpoints.removeValue(forKey: key)
            lastPresetStartErrors.removeValue(forKey: key)
            lastAttachErrors.removeValue(forKey: key)
        }
    }

    private func detachEndpoints(threadID: String) {
        let keys = attachedEndpoints.keys.filter { $0.threadID == threadID }
        for key in keys {
            multiplexer?.detach(threadID: key.threadID, sessionID: key.sessionID)
            attachedEndpoints.removeValue(forKey: key)
            lastPresetStartErrors.removeValue(forKey: key)
            lastAttachErrors.removeValue(forKey: key)
        }
        refreshSelectedEndpoint()
    }

    private func detachEndpoint(threadID: String, preset: String) {
        let key = AttachmentKey(threadID: threadID, sessionID: preset)
        guard attachedEndpoints.removeValue(forKey: key) != nil else {
            refreshSelectedEndpoint()
            return
        }

        multiplexer?.detach(threadID: threadID, sessionID: preset)
        lastPresetStartErrors.removeValue(forKey: key)
        lastAttachErrors.removeValue(forKey: key)
        refreshSelectedEndpoint()
    }

    private func defaultConnectionManager() -> (any ConnectionManaging)? {
        guard let connectionPool else {
            return nil
        }

        if let activeRemoteID = connectionPool.activeRemoteId,
           let activeConnection = connectionPool.connection(for: activeRemoteID)
        {
            return activeConnection
        }

        if let firstRemoteID = remotes.first?.id {
            return connectionPool.connection(for: firstRemoteID)
        }

        return nil
    }

    private func currentConnectionDebugSnapshot() -> ConnectionDebugSnapshot {
        if let threadID = selectedThreadID,
           let connection = connectionForThread(id: threadID)
        {
            return connection.debugSnapshot
        }

        return defaultConnectionManager()?.debugSnapshot ?? ConnectionDebugSnapshot(
            status: connectionStatus.label,
            sessionReady: false,
            reconnectAttempt: 0,
            lastErrorDescription: nil
        )
    }

    func connectionForThread(id threadID: String) -> (any ConnectionManaging)? {
        guard let connectionPool else {
            return nil
        }

        guard let remoteID = remoteIDForThread(id: threadID) else {
            return defaultConnectionManager()
        }
        return connectionPool.connection(for: remoteID)
    }

    private func connectionForProject(id projectID: String) -> (any ConnectionManaging)? {
        guard let connectionPool else {
            return nil
        }

        guard let remoteID = remoteIDForProject(id: projectID) else {
            return defaultConnectionManager()
        }
        return connectionPool.connection(for: remoteID)
    }

    private func remoteIDForThread(id threadID: String) -> String? {
        guard let projectID = threads.first(where: { $0.id == threadID })?.projectId else {
            return nil
        }
        return remoteIDForProject(id: projectID)
    }

    private func remoteIDForProject(id projectID: String) -> String? {
        projectsByID[projectID]?.remoteId
    }

    private func linkProject(
        projectID: String,
        repoID: String,
        remoteID: String,
        projectName: String,
        remotePath: String,
        defaultBranch: String
    ) {
        var shouldPersistLink = true

        if let projectIndex = projects.firstIndex(where: { $0.id == projectID }) {
            let existingProject = projects[projectIndex]
            shouldPersistLink = existingProject.repoId != repoID || existingProject.remoteId != remoteID
            projects[projectIndex].repoId = repoID
            projects[projectIndex].remoteId = remoteID
            projects[projectIndex].name = projectName
            projects[projectIndex].remotePath = remotePath
        } else {
            projects.append(
                Project(
                    id: projectID,
                    name: projectName,
                    remotePath: remotePath,
                    defaultBranch: defaultBranch,
                    presets: [],
                    agents: [],
                    remoteId: remoteID,
                    repoId: repoID
                )
            )
        }

        guard shouldPersistLink else {
            return
        }

        do {
            _ = try databaseManager?.linkProject(projectID: projectID, repoID: repoID, remoteID: remoteID)
        } catch {
            Logger.state.error("Failed to link project metadata (\(projectID)): \(error)")
        }
    }

    private func selectedRemoteID() -> String? {
        if let selectedThreadID,
           let remoteID = remoteIDForThread(id: selectedThreadID)
        {
            return remoteID
        }

        if let selectedWorkspaceRemoteID {
            return selectedWorkspaceRemoteID
        }

        if let activeRemoteID = connectionPool?.activeRemoteId {
            return activeRemoteID
        }

        return remotes.first?.id
    }

    private var visibleThreads: [ThreadModel] {
        return threads.filter { thread in
            guard thread.status != .closed, thread.status != .failed else {
                return false
            }

            guard thread.sourceType == "main_checkout" else {
                return true
            }

            guard let project = projectsByID[thread.projectId] else {
                Logger.state.error("main_checkout thread \(thread.id) references unknown project \(thread.projectId)")
                return false
            }

            return isDefaultWorkspaceProject(project)
        }
    }

    private func updateActiveRemoteConnection() {
        guard let connectionPool, let remoteID = selectedRemoteID() else {
            return
        }

        Task { @MainActor [weak self] in
            do {
                try connectionPool.activate(remoteId: remoteID)
                try await connectionPool.ensureConnected(remoteId: remoteID)
            } catch {
                Logger.state.error("Failed to activate remote connection (\(remoteID)): \(error)")
            }

            if let activeConnection = self?.connectionPool?.connection(for: remoteID) {
                self?.connectionStatus = activeConnection.state
            }
        }
    }

    private func syncRemoteState(forProjectID projectID: String, using connection: any ConnectionManaging) async {
        guard let databaseManager, let remoteID = remoteIDForProject(id: projectID) else {
            await syncService?.syncFromDaemon()
            return
        }

        let syncService = SyncService(
            connectionManager: connection,
            databaseManager: databaseManager,
            appState: self,
            remoteId: remoteID
        )
        await syncService.syncFromDaemon()
    }

    private func injectDefaultWorkspaceRepo() {
        guard !repos.contains(where: \.isDefaultWorkspace) else {
            return
        }
        repos.insert(.defaultWorkspace, at: 0)

        do {
            try databaseManager?.saveRepo(.defaultWorkspace)
        } catch {
            Logger.state.error("Failed to persist default workspace repo: \(error)")
        }
    }

    private func normalizeDefaultWorkspaceProjects() {
        for project in projects where isDefaultWorkspaceProject(project) {
            guard let remoteID = project.remoteId else {
                continue
            }
            guard project.repoId == nil || project.repoId == Repo.defaultWorkspaceID else {
                continue
            }
            linkProject(
                projectID: project.id,
                repoID: Repo.defaultWorkspaceID,
                remoteID: remoteID,
                projectName: Repo.defaultWorkspace.name,
                remotePath: project.remotePath,
                defaultBranch: project.defaultBranch
            )
        }
    }

    private func ensureDefaultWorkspaceOnRemote(remote: Remote) async throws -> String {
        if let projectID = projects.first(where: { isDefaultWorkspaceProject($0) && $0.remoteId == remote.id })?.id {
            return projectID
        }

        let path = remote.defaultWorkspacePath
        let lookup = try await lookupProject(path: path, on: remote.id)
        let projectID: String

        if let existingProjectID = lookup.projectId {
            if let existingProject = projectsByID[existingProjectID],
               let existingRepoID = existingProject.repoId,
               existingRepoID != Repo.defaultWorkspaceID
            {
                Logger.state.error("Refusing to relink project \(existingProjectID) already linked to repo \(existingRepoID) as cross-project workspace")
                throw AppStateError.defaultWorkspaceProjectAlreadyLinked(
                    projectID: existingProjectID,
                    repoID: existingRepoID
                )
            }
            projectID = existingProjectID
        } else {
            guard let connection = connectionPool?.connection(for: remote.id) else {
                throw AppStateError.connectionManagerUnavailable
            }
            let result = try await connection.request(method: "project.add", params: ["path": path], timeout: 20)
            guard let payload = result as? [String: Any], let createdProjectID = payload["id"] as? String else {
                throw AppStateError.invalidProjectResponse
            }
            projectID = createdProjectID
        }

        linkProject(
            projectID: projectID,
            repoID: Repo.defaultWorkspaceID,
            remoteID: remote.id,
            projectName: Repo.defaultWorkspace.name,
            remotePath: path,
            defaultBranch: Repo.defaultWorkspace.defaultBranch
        )
        return projectID
    }

    private func startStatsTimer() {
        guard statsPollingEnabled, statsTask == nil else {
            return
        }

        statsTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.refreshSystemStats()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.statsRefreshIntervalNanoseconds)
                } catch {
                    return
                }

                if Task.isCancelled {
                    return
                }

                await self.refreshSystemStats()
            }
        }
    }

    private func stopStatsTimer() {
        statsTask?.cancel()
        statsTask = nil
    }

    private func refreshSystemStats() async {
        guard case .connected = connectionStatus, let connectionManager else {
            return
        }

        do {
            let result = try await connectionManager.request(
                method: "system.stats",
                params: nil,
                timeout: 5
            )

            guard JSONSerialization.isValidJSONObject(result) else {
                systemStats = nil
                return
            }

            let payload = try JSONSerialization.data(withJSONObject: result)
            systemStats = try JSONDecoder().decode(SystemStatsResult.self, from: payload)
        } catch {
            systemStats = nil
            Logger.state.error("Failed to refresh system stats: \(error)")
        }
    }

    func cleanupSystem() async {
        guard case .connected = connectionStatus, let connectionManager else {
            return
        }

        do {
            _ = try await connectionManager.request(
                method: "system.cleanup",
                params: nil,
                timeout: 30
            )
            await refreshSystemStats()
        } catch {
            Logger.state.error("Failed to cleanup system: \(error)")
        }
    }

    func shutdown() {
        stopStatsTimer()
    }

    // MARK: - Keyboard shortcut actions

    func selectThreadByIndex(_ index: Int) {
        guard index >= 0, index < threads.count else { return }
        selectedThreadID = threads[index].id
    }

    func openNewThreadSheet() {
        if repos.isEmpty {
            alertMessage = "Add a repository first (Cmd+Shift+A)"
            return
        }
        if remotes.isEmpty {
            alertMessage = "Configure a remote in Settings (Cmd+,)"
            return
        }
        isNewThreadSheetPresented = true
    }

    func closeSelectedThread() {
        guard let threadID = selectedThreadID else { return }
        Task { await closeThread(threadID: threadID) }
    }

    func nextPresetTab() {
        let names = presets.map(\.name)
        guard !names.isEmpty else { return }
        guard let current = selectedPreset, let idx = names.firstIndex(of: current) else {
            selectedPreset = names[0]
            return
        }
        selectedPreset = names[(idx + 1) % names.count]
    }

    func previousPresetTab() {
        let names = presets.map(\.name)
        guard !names.isEmpty else { return }
        guard let current = selectedPreset, let idx = names.firstIndex(of: current) else {
            selectedPreset = names[0]
            return
        }
        selectedPreset = names[(idx - 1 + names.count) % names.count]
    }

    func restartCurrentPreset() {
        guard
            let threadID = selectedThreadID,
            let preset = selectedPreset,
            presets.contains(where: { $0.name == preset }),
            let connectionManager
        else {
            return
        }
        Task {
            do {
                _ = try await connectionManager.request(
                    method: "preset.restart",
                    params: ["thread_id": threadID, "preset": preset],
                    timeout: 20
                )
            } catch {
                Logger.state.error("preset.restart failed: \(error)")
            }
        }
    }

    func toggleConnection() {
        guard let connectionManager else { return }
        if connectionManager.state.isConnected {
            connectionManager.stop()
        } else {
            connectionManager.start()
        }
    }
}
