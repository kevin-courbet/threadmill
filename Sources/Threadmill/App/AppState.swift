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
            refreshSelectedEndpoint()
        }
    }
    var selectedPreset: String? = Preset.defaults.first?.name {
        didSet {
            refreshSelectedEndpoint()
        }
    }
    var selectedEndpoint: RelayEndpoint?

    private var databaseManager: DatabaseManager?
    private var syncService: SyncService?
    private var multiplexer: TerminalMultiplexer?
    private var connectionManager: ConnectionManager?
    private var eventSyncScheduled = false
    private var attachedEndpoints: [AttachmentKey: RelayEndpoint] = [:]

    var selectedThread: ThreadModel? {
        threads.first { $0.id == selectedThreadID }
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
        Preset.defaults
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
        connectionManager: ConnectionManager,
        databaseManager: DatabaseManager,
        syncService: SyncService,
        multiplexer: TerminalMultiplexer
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
        default:
            break
        }
    }

    func attachSelectedPreset() async {
        guard let selectedThread else {
            selectedEndpoint = nil
            return
        }

        let preset = selectedPreset ?? presets.first?.name ?? "terminal"
        let key = AttachmentKey(threadID: selectedThread.id, preset: preset)

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
                            "thread_id": selectedThread.id,
                            "preset": preset,
                        ],
                        timeout: 20
                    )
                    _ = try await multiplexer.attach(threadID: selectedThread.id, preset: preset)
                } catch {
                    NSLog("threadmill-state: reattach failed: %@", "\(error)")
                }
            }
            return
        }

        do {
            _ = try await connectionManager.request(
                method: "preset.start",
                params: [
                    "thread_id": selectedThread.id,
                    "preset": preset,
                ],
                timeout: 20
            )

            let endpoint = try await multiplexer.attach(threadID: selectedThread.id, preset: preset)
            attachedEndpoints[key] = endpoint
            selectedEndpoint = endpoint
        } catch {
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

        if status == .closed || status == .hidden {
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

        if threadID != "unknown", let errorText, !errorText.isEmpty {
            _ = updateThreadStatus(threadID: threadID, status: .failed)
        }

        if let errorText, !errorText.isEmpty {
            NSLog("threadmill-state: thread.progress thread=%@ step=%@ message=%@ error=%@", threadID, step, message, errorText)
        } else {
            NSLog("threadmill-state: thread.progress thread=%@ step=%@ message=%@", threadID, step, message)
        }
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
