import Foundation
import Observation

enum AppStateError: LocalizedError {
    case connectionManagerUnavailable
    case invalidGitStatusResponse
    case provisioningUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionManagerUnavailable:
            "Connection to spindle is unavailable."
        case .invalidGitStatusResponse:
            "Invalid response for file.git_status."
        case .provisioningUnavailable:
            "Provisioning service is unavailable."
        }
    }
}

@MainActor
@Observable
final class AppState {
    private struct AttachmentKey: Hashable {
        let threadID: String
        let preset: String
    }

    var connectionStatus: ConnectionStatus = .disconnected {
        didSet {
            if case .connected = connectionStatus, oldValue != connectionStatus {
                scheduleAttachSelectedPreset()
                startStatsTimer()
            } else if connectionStatus == .disconnected {
                stopStatsTimer()
                systemStats = nil
            }
        }
    }
    var remotes: [Remote] = []
    var repos: [Repo] = []
    var projects: [Project] = []
    var threads: [ThreadModel] = []
    var systemStats: SystemStatsResult?
    private var statsTimer: Timer?

    var isNewThreadSheetPresented = false
    var selectedThreadID: String? {
        didSet {
            ensureSelectedPresetIsValid()
            refreshSelectedEndpoint()
            updateActiveRemoteConnection()
        }
    }
    var selectedPreset: String? {
        didSet {
            refreshSelectedEndpoint()
        }
    }
    var selectedEndpoint: RelayEndpoint?
    private(set) var openCodeClient: (any OpenCodeManaging)?
    private(set) var chatConversationService: (any ChatConversationManaging)?
    private(set) var fileService: (any FileBrowsing)?

    private(set) var databaseManager: (any DatabaseManaging)?
    private var provisioningService: (any Provisioning)?
    private var syncService: (any SyncServicing)?
    private var multiplexer: (any TerminalMultiplexing)?
    private var connectionPool: (any RemoteConnectionPooling)?
    private var eventSyncScheduled = false
    private var attachedEndpoints: [AttachmentKey: RelayEndpoint] = [:]
    private var pendingAttachTasks: [AttachmentKey: Task<Void, Never>] = [:]
    private var permanentAttachFailures: Set<AttachmentKey> = []

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
        return projects.first { $0.id == projectID }
    }

    var activeRemoteID: String? {
        if let activeRemoteID = connectionPool?.activeRemoteId {
            return activeRemoteID
        }
        return remotes.first?.id
    }

    func connectionForSelectedThread() -> (any ConnectionManaging)? {
        guard let selectedThreadID else {
            return nil
        }
        return connectionForThread(id: selectedThreadID)
    }

    var projectsWithThreads: [(Project, [ThreadModel])] {
        let grouped = Dictionary(grouping: visibleThreads, by: \.projectId)
        return projects
            .filter { $0.repoId == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { project in
                let rows = (grouped[project.id] ?? []).sorted { $0.createdAt > $1.createdAt }
                return (project, rows)
            }
    }

    var reposWithThreads: [(Repo, [ThreadModel])] {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: visibleThreads) { thread in
            projectsByID[thread.projectId]?.repoId
        }

        return repos
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
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
            .filter { openPresetNames.contains($0) || selectedPreset == $0 }

        let terminalTabs: [TerminalTabModel] = visiblePresetNames.compactMap { presetName in
            guard let preset = presets.first(where: { $0.name == presetName }) else {
                return nil
            }

            return TerminalTabModel(
                threadID: thread.id,
                type: .terminal(preset),
                endpoint: attachedEndpoints[AttachmentKey(threadID: thread.id, preset: presetName)]
            )
        }

        return terminalTabs + [
            TerminalTabModel(threadID: thread.id, type: .chat, endpoint: nil)
        ]
    }

    func configure(
        connectionPool: any RemoteConnectionPooling,
        databaseManager: any DatabaseManaging,
        syncService: any SyncServicing,
        multiplexer: any TerminalMultiplexing,
        provisioningService: (any Provisioning)? = nil,
        openCodeClient: any OpenCodeManaging = OpenCodeClient(),
        chatConversationService: (any ChatConversationManaging)? = nil,
        fileService: (any FileBrowsing)? = nil
    ) {
        self.connectionPool = connectionPool
        self.databaseManager = databaseManager
        self.provisioningService = provisioningService ?? ProvisioningService(connectionPool: connectionPool)
        self.syncService = syncService
        self.multiplexer = multiplexer
        self.openCodeClient = openCodeClient
        self.chatConversationService = chatConversationService
        self.fileService = fileService ?? FileService(connectionProvider: { [weak self] in
            self?.connectionForSelectedThread() ?? self?.defaultConnectionManager()
        })
    }

    func ensureValidSelection() {
        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) {
            return
        }
        selectedThreadID = threads.first?.id
    }

    func reloadFromDatabase() {
        guard let databaseManager else {
            return
        }

        do {
            remotes = try databaseManager.allRemotes()
            repos = try databaseManager.allRepos()
            projects = try databaseManager.allProjects()
            threads = try databaseManager.allThreads()
            pruneDetachedThreadEndpoints()
            ensureValidSelection()
            ensureSelectedPresetIsValid()
            refreshSelectedEndpoint()
            updateActiveRemoteConnection()
        } catch {
            NSLog("threadmill-state: failed to load cache: %@", "\(error)")
        }
    }

    func syncNow() async {
        await syncService?.syncFromDaemon()
    }

    func handleDaemonEvent(method: String, params: [String: Any]?) {
        switch method {
        case "thread.status_changed":
            handleThreadStatusChanged(params)
        case "thread.progress":
            handleThreadProgress(params)
        case "project.clone_progress":
            handleProjectCloneProgress(params)
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
        Task { @MainActor [weak self] in
            await self?.attachSelectedPreset()
        }
    }

    func attachSelectedPreset() async {
        guard let selectedThread else {
            cancelPendingAttachTasks()
            selectedEndpoint = nil
            return
        }

        if selectedPreset == TerminalTabModel.chatTabSelectionID {
            cancelPendingAttachTasks(threadID: selectedThread.id)
            selectedEndpoint = nil
            return
        }

        guard let preset = selectedPreset ?? presets.first?.name else {
            selectedEndpoint = nil
            return
        }

        let availablePresetNames = Set(presets.map(\.name))
        guard availablePresetNames.contains(preset) else {
            selectedPreset = presets.first?.name
            selectedEndpoint = nil
            return
        }

        await attachPreset(threadID: selectedThread.id, preset: preset)
    }

    func attachPreset(threadID: String, preset: String) async {
        guard selectedThreadID == threadID else {
            return
        }

        guard presets.contains(where: { $0.name == preset }) else {
            selectedPreset = presets.first?.name
            selectedEndpoint = nil
            return
        }

        selectedPreset = preset

        let key = AttachmentKey(threadID: threadID, preset: preset)

        cancelPendingAttachTasks(except: key)
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
            await self.performAttachPreset(threadID: threadID, preset: preset, key: key)
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

    func startPreset(threadID: String, preset: String) async {
        guard selectedThreadID == threadID,
              let connectionManager = connectionForThread(id: threadID)
        else {
            return
        }
        guard presets.contains(where: { $0.name == preset }) else {
            return
        }

        do {
            _ = try await connectionManager.request(
                method: "preset.start",
                params: [
                    "thread_id": threadID,
                    "preset": preset,
                ],
                timeout: 20
            )
        } catch {
            NSLog("threadmill-state: preset.start failed (%@/%@): %@", threadID, preset, "\(error)")
            return
        }

        selectedPreset = preset
        await attachPreset(threadID: threadID, preset: preset)
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

        let key = AttachmentKey(threadID: threadID, preset: preset)

        do {
            _ = try await connectionManager.request(
                method: "preset.stop",
                params: [
                    "thread_id": threadID,
                    "preset": preset,
                ],
                timeout: 20
            )

            pendingAttachTasks[key]?.cancel()
            pendingAttachTasks.removeValue(forKey: key)
            permanentAttachFailures.remove(key)

            let wasSelected = selectedPreset == preset
            if wasSelected {
                selectedPreset = nil
            }

            detachEndpoint(threadID: threadID, preset: preset)

            if wasSelected {
                let replacement = presets
                    .map(\.name)
                    .first(where: { openPresetNames(for: threadID).contains($0) })
                selectedPreset = replacement
                if replacement == nil {
                    selectedEndpoint = nil
                }
            }
        } catch {
            NSLog("threadmill-state: preset.stop failed (%@/%@): %@", threadID, preset, "\(error)")
        }
    }

    private func performAttachPreset(threadID requestedThreadID: String, preset requestedPreset: String, key: AttachmentKey) async {
        guard canAttemptAttach(threadID: requestedThreadID, key: key) else {
            if selectedThreadID == requestedThreadID && selectedPreset == requestedPreset {
                selectedEndpoint = attachedEndpoints[key]
            }
            return
        }

        func selectionMatchesRequest() -> Bool {
            selectedThreadID == requestedThreadID && selectedPreset == requestedPreset
        }

        guard selectionMatchesRequest() else {
            return
        }

        guard let connectionManager = connectionForThread(id: requestedThreadID), let multiplexer else {
            return
        }

        if let endpoint = attachedEndpoints[key] {
            guard selectionMatchesRequest() else {
                return
            }
            selectedEndpoint = endpoint
            if endpoint.channelID == 0, connectionManager.state.isConnected {
                do {
                    let reattachedEndpoint = try await multiplexer.attach(threadID: requestedThreadID, preset: requestedPreset)
                    guard selectionMatchesRequest(), canAttemptAttach(threadID: requestedThreadID, key: key) else {
                        return
                    }

                    attachedEndpoints[key] = reattachedEndpoint
                    selectedEndpoint = reattachedEndpoint
                } catch {
                    handleAttachError(error, key: key, threadID: requestedThreadID)
                    NSLog("threadmill-state: reattach failed: %@", "\(error)")
                }
            }
            return
        }

        do {
            _ = try await connectionManager.request(
                method: "preset.start",
                params: [
                    "thread_id": requestedThreadID,
                    "preset": requestedPreset,
                ],
                timeout: 20
            )
            guard selectionMatchesRequest(), canAttemptAttach(threadID: requestedThreadID, key: key) else {
                return
            }

            let endpoint = try await multiplexer.attach(threadID: requestedThreadID, preset: requestedPreset)
            guard selectionMatchesRequest(), canAttemptAttach(threadID: requestedThreadID, key: key) else {
                return
            }

            attachedEndpoints[key] = endpoint
            selectedEndpoint = endpoint
        } catch {
            handleAttachError(error, key: key, threadID: requestedThreadID)
            NSLog("threadmill-state: attach failed: %@", "\(error)")
        }
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
            NSLog("threadmill-state: thread.hide failed (%@): %@", threadID, "\(error)")
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
            NSLog("threadmill-state: thread.close failed (%@): %@", threadID, "\(error)")
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
            NSLog("threadmill-state: thread.cancel failed (%@): %@", threadID, "\(error)")
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
            repoOwner: repo.owner,
            repoName: repo.name,
            remoteCloneRoot: remote.cloneRoot,
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
        let projectID = try await ensureRepoOnRemote(repo: repo, remote: remote)
        try await createThread(
            projectID: projectID,
            name: name,
            sourceType: sourceType,
            branch: branch,
            prURL: prURL
        )
        linkProject(
            projectID: projectID,
            repoID: repo.id,
            remoteID: remote.id,
            repoOwner: repo.owner,
            repoName: repo.name,
            remoteCloneRoot: remote.cloneRoot,
            defaultBranch: repo.defaultBranch
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
            NSLog("threadmill-state: thread.reopen failed (%@): %@", threadID, "\(error)")
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
            NSLog("threadmill-state: project.remove failed (%@): %@", projectID, "\(error)")
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

    func ensureOpenCodeRunning() async throws {
        guard let connectionManager else {
            throw AppStateError.connectionManagerUnavailable
        }

        _ = try await connectionManager.request(
            method: "opencode.ensure",
            params: nil,
            timeout: 15
        )
    }

    func createThread(
        projectID: String,
        name: String,
        sourceType: String,
        branch: String?,
        prURL: String? = nil
    ) async throws {
        NSLog(
            "threadmill-state: createThread start project=%@ name=%@ source=%@ branch=%@ pr_url=%@",
            projectID,
            name,
            sourceType,
            branch ?? "<nil>",
            prURL ?? "<nil>"
        )

        guard let connectionManager = connectionForProject(id: projectID) else {
            NSLog("threadmill-state: createThread aborted, connection manager unavailable")
            throw AppStateError.connectionManagerUnavailable
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
            NSLog("threadmill-state: createThread request sent")
            await syncService?.syncFromDaemon()
            NSLog("threadmill-state: createThread sync complete")
        } catch {
            NSLog("threadmill-state: createThread failed: %@", "\(error)")
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
            NSLog("threadmill-state: invalid thread.status_changed payload: %@", "\(params ?? [:])")
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
            NSLog("threadmill-state: thread.progress payload missing")
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
            NSLog("threadmill-state: thread.progress thread=%@ step=%@ message=%@ error=%@", threadID, step, message, errorText)
        } else {
            NSLog("threadmill-state: thread.progress thread=%@ step=%@ message=%@", threadID, step, message)
        }
    }

    private func handleProjectCloneProgress(_ params: [String: Any]?) {
        guard let params else {
            NSLog("threadmill-state: project.clone_progress payload missing")
            return
        }

        let cloneID = params["thread_id"] as? String ?? "unknown"
        let step = params["step"] as? String ?? "unknown"
        let message = params["message"] as? String ?? ""
        let errorText = params["error"] as? String

        if let errorText, !errorText.isEmpty {
            NSLog("threadmill-state: project.clone_progress clone=%@ step=%@ message=%@ error=%@", cloneID, step, message, errorText)
        } else {
            NSLog("threadmill-state: project.clone_progress clone=%@ step=%@ message=%@", cloneID, step, message)
        }
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
            NSLog("threadmill-state: failed to persist thread status (%@): %@", threadID, "\(error)")
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
        guard isPermanentTerminalAttachError(error) else {
            return
        }
        permanentAttachFailures.insert(key)
        cancelPendingAttachTasks(threadID: threadID)
        detachEndpoint(threadID: threadID, preset: key.preset)
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

        selectedEndpoint = attachedEndpoints[AttachmentKey(threadID: threadID, preset: preset)]
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

        if let selectedPreset, availablePresets.contains(selectedPreset) {
            return
        }

        selectedPreset = availablePresets[0]
    }

    private func openPresetNames(for threadID: String) -> Set<String> {
        Set(attachedEndpoints.keys.filter { $0.threadID == threadID }.map(\.preset))
    }

    private func pruneDetachedThreadEndpoints() {
        let validThreadIDs = Set(threads.map(\.id))
        let staleKeys = attachedEndpoints.keys.filter { !validThreadIDs.contains($0.threadID) }
        for key in staleKeys {
            multiplexer?.detach(threadID: key.threadID, preset: key.preset)
            attachedEndpoints.removeValue(forKey: key)
        }
    }

    private func detachEndpoints(threadID: String) {
        let keys = attachedEndpoints.keys.filter { $0.threadID == threadID }
        for key in keys {
            multiplexer?.detach(threadID: key.threadID, preset: key.preset)
            attachedEndpoints.removeValue(forKey: key)
        }
        refreshSelectedEndpoint()
    }

    private func detachEndpoint(threadID: String, preset: String) {
        let key = AttachmentKey(threadID: threadID, preset: preset)
        guard attachedEndpoints.removeValue(forKey: key) != nil else {
            refreshSelectedEndpoint()
            return
        }

        multiplexer?.detach(threadID: threadID, preset: preset)
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
        projects.first(where: { $0.id == projectID })?.remoteId
    }

    private func linkProject(
        projectID: String,
        repoID: String,
        remoteID: String,
        repoOwner: String,
        repoName: String,
        remoteCloneRoot: String,
        defaultBranch: String
    ) {
        if let projectIndex = projects.firstIndex(where: { $0.id == projectID }) {
            projects[projectIndex].repoId = repoID
            projects[projectIndex].remoteId = remoteID
        } else {
            projects.append(
                Project(
                    id: projectID,
                    name: repoName,
                    remotePath: Remote.joinedRemotePath(root: remoteCloneRoot, owner: repoOwner, repoName: repoName),
                    defaultBranch: defaultBranch,
                    presets: [],
                    remoteId: remoteID,
                    repoId: repoID
                )
            )
        }

        do {
            _ = try databaseManager?.linkProject(projectID: projectID, repoID: repoID, remoteID: remoteID)
        } catch {
            NSLog("threadmill-state: failed to link project metadata (%@): %@", projectID, "\(error)")
        }
    }

    private func selectedRemoteID() -> String? {
        if let selectedThreadID,
           let remoteID = remoteIDForThread(id: selectedThreadID)
        {
            return remoteID
        }

        if let activeRemoteID = connectionPool?.activeRemoteId {
            return activeRemoteID
        }

        return remotes.first?.id
    }

    private var visibleThreads: [ThreadModel] {
        threads.filter { thread in
            thread.status != .closed
                && thread.status != .failed
                && thread.sourceType != "main_checkout"
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
                NSLog("threadmill-state: failed to activate remote connection (%@): %@", remoteID, "\(error)")
            }

            if let activeConnection = self?.connectionPool?.connection(for: remoteID) {
                self?.connectionStatus = activeConnection.state
            }
        }
    }

    private func startStatsTimer() {
        guard statsTimer == nil else {
            return
        }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshSystemStats()
            }
        }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
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
            NSLog("threadmill-state: failed to refresh system stats: %@", "\(error)")
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
            NSLog("threadmill-state: failed to cleanup system: %@", "\(error)")
        }
    }

    // MARK: - Keyboard shortcut actions

    func selectThreadByIndex(_ index: Int) {
        guard index >= 0, index < threads.count else { return }
        selectedThreadID = threads[index].id
    }

    func openNewThreadSheet() {
        guard !repos.isEmpty, !remotes.isEmpty else {
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
                NSLog("threadmill-state: preset.restart failed: %@", "\(error)")
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
