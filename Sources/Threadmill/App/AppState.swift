import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private struct AttachmentKey: Hashable {
        let threadID: String
        let preset: String
    }

    var connectionStatus: ConnectionStatus = .disconnected
    var projects: [Project] = []
    var threads: [ThreadModel] = []
    var selectedThreadID: String? {
        didSet {
            ensureSelectedPresetIsValid()
            refreshSelectedEndpoint()
        }
    }
    var selectedPreset: String? {
        didSet {
            refreshSelectedEndpoint()
        }
    }
    var selectedEndpoint: RelayEndpoint?

    private var databaseManager: (any DatabaseManaging)?
    private var syncService: (any SyncServicing)?
    private var multiplexer: (any TerminalMultiplexing)?
    private var connectionManager: (any ConnectionManaging)?
    private var eventSyncScheduled = false
    private var attachedEndpoints: [AttachmentKey: RelayEndpoint] = [:]
    private var pendingAttachTasks: [AttachmentKey: Task<Void, Never>] = [:]
    private var permanentAttachFailures: Set<AttachmentKey> = []

    var selectedThread: ThreadModel? {
        threads.first { $0.id == selectedThreadID }
    }

    var selectedProject: Project? {
        guard let projectID = selectedThread?.projectId else {
            return nil
        }
        return projects.first { $0.id == projectID }
    }

    var projectsWithThreads: [(Project, [ThreadModel])] {
        let grouped = Dictionary(grouping: threads, by: \.projectId)
        return projects
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { project in
                let rows = (grouped[project.id] ?? []).sorted { $0.createdAt > $1.createdAt }
                return (project, rows)
            }
    }

    var presets: [Preset] {
        guard let selectedProject else {
            return []
        }
        return selectedProject.presets.map { Preset(name: $0.name) }
    }

    var terminalTabs: [TerminalTabModel] {
        guard let thread = selectedThread else {
            return []
        }
        return presets.map { preset in
            TerminalTabModel(
                threadID: thread.id,
                preset: preset,
                endpoint: attachedEndpoints[AttachmentKey(threadID: thread.id, preset: preset.name)]
            )
        }
    }

    func configure(
        connectionManager: any ConnectionManaging,
        databaseManager: any DatabaseManaging,
        syncService: any SyncServicing,
        multiplexer: any TerminalMultiplexing
    ) {
        self.connectionManager = connectionManager
        self.databaseManager = databaseManager
        self.syncService = syncService
        self.multiplexer = multiplexer
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
            projects = try databaseManager.allProjects()
            threads = try databaseManager.allThreads()
            pruneDetachedThreadEndpoints()
            ensureValidSelection()
            ensureSelectedPresetIsValid()
            refreshSelectedEndpoint()
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

        guard let preset = selectedPreset ?? presets.first?.name else {
            selectedEndpoint = nil
            return
        }
        let requestedThreadID = selectedThread.id
        let key = AttachmentKey(threadID: requestedThreadID, preset: preset)

        cancelPendingAttachTasks(except: key)
        guard canAttemptAttach(threadID: requestedThreadID, key: key) else {
            cancelPendingAttachTasks(threadID: requestedThreadID)
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
            await self.attachPreset(threadID: requestedThreadID, preset: preset, key: key)
        }
        pendingAttachTasks[key] = task
        await task.value
    }

    private func attachPreset(threadID requestedThreadID: String, preset requestedPreset: String, key: AttachmentKey) async {
        guard canAttemptAttach(threadID: requestedThreadID, key: key) else {
            if selectedThreadID == requestedThreadID && selectedPreset == requestedPreset {
                selectedEndpoint = attachedEndpoints[key]
            }
            return
        }

        func selectionMatchesRequest() -> Bool {
            selectedThreadID == requestedThreadID && selectedPreset == requestedPreset
        }

        guard let connectionManager, let multiplexer else {
            return
        }

        if let endpoint = attachedEndpoints[key] {
            selectedEndpoint = endpoint
            if endpoint.channelID == 0, connectionManager.state.isConnected {
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

                    _ = try await multiplexer.attach(threadID: requestedThreadID, preset: requestedPreset)
                    guard selectionMatchesRequest(), canAttemptAttach(threadID: requestedThreadID, key: key) else {
                        return
                    }
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
        guard let connectionManager else {
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
        guard let connectionManager else {
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

    func reopenThread(threadID: String) async {
        guard let connectionManager else {
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

    func browseDirectories(path: String) async throws -> [String] {
        guard let connectionManager else {
            return []
        }

        let result = try await connectionManager.request(
            method: "project.browse",
            params: ["path": path],
            timeout: 10
        )

        guard let entries = result as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            guard
                let isDir = entry["is_dir"] as? Bool,
                isDir,
                let name = entry["name"] as? String
            else {
                return nil
            }

            return URL(fileURLWithPath: path).appendingPathComponent(name).path
        }
        .sorted()
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
        guard let connectionManager else {
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
        branch: String?
    ) async throws {
        guard let connectionManager else {
            return
        }

        var params: [String: Any] = [
            "project_id": projectID,
            "name": name,
            "source_type": sourceType,
        ]

        if let branch, !branch.isEmpty {
            params["branch"] = branch
        }

        _ = try await connectionManager.request(method: "thread.create", params: params, timeout: 30)
        await syncService?.syncFromDaemon()
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
            let preset = selectedPreset
        else {
            selectedEndpoint = nil
            return
        }

        selectedEndpoint = attachedEndpoints[AttachmentKey(threadID: threadID, preset: preset)]
    }

    private func ensureSelectedPresetIsValid() {
        let availablePresets = presets.map(\.name)
        guard !availablePresets.isEmpty else {
            selectedPreset = nil
            return
        }

        if let selectedPreset, availablePresets.contains(selectedPreset) {
            return
        }

        selectedPreset = availablePresets[0]
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
}
