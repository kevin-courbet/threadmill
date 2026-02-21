import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var connectionStatus: ConnectionStatus = .disconnected
    var projects: [Project] = []
    var threads: [ThreadModel] = []
    var selectedThreadID: String?
    var selectedPreset: String? = Preset.defaults.first?.name
    var selectedEndpoint: RelayEndpoint?

    private var databaseManager: DatabaseManager?
    private var syncService: SyncService?
    private var multiplexer: TerminalMultiplexer?
    private var connectionManager: ConnectionManager?

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
            ensureValidSelection()
        } catch {
            NSLog("threadmill-state: failed to load cache: %@", "\(error)")
        }
    }

    func syncNow() async {
        await syncService?.syncFromDaemon()
    }

    func attachSelectedPreset() async {
        guard let selectedThread else {
            await detachCurrentTerminal()
            return
        }
        let preset = selectedPreset ?? Preset.defaults.first?.name ?? "terminal"

        if let endpoint = selectedEndpoint,
           endpoint.threadID == selectedThread.id,
           endpoint.preset == preset {
            return
        }

        await detachCurrentTerminal()

        guard let multiplexer else {
            return
        }

        do {
            selectedEndpoint = try await multiplexer.attach(threadID: selectedThread.id, preset: preset)
        } catch {
            NSLog("threadmill-state: attach failed: %@", "\(error)")
        }
    }

    func detachCurrentTerminal() async {
        guard let endpoint = selectedEndpoint else {
            return
        }
        multiplexer?.detach(channelID: endpoint.channelID)
        selectedEndpoint = nil
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
        sourceRef: String?
    ) async throws {
        guard let connectionManager else {
            return
        }

        var params: [String: Any] = [
            "project_id": projectID,
            "name": name,
            "source_type": sourceType,
        ]
        if let sourceRef, !sourceRef.isEmpty {
            params["source_ref"] = sourceRef
        }

        _ = try await connectionManager.request(method: "thread.create", params: params, timeout: 30)
        await syncService?.syncFromDaemon()
    }
}
