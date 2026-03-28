import SwiftUI
import XCTest
@testable import Threadmill

@MainActor
final class AppStateInteractionBehaviorTests: XCTestCase {
    func testCreateThreadTransitionsFromCreatingToActive() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.sessionReady = false
        connection.reconnectAttempt = 2
        connection.lastErrorDescription = "handshake pending"
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        database.projects = [project]

        let creatingThread = makeThread(id: "thread-1", projectID: project.id, status: .creating)
        connection.requestHandler = { method, _, _ in
            if method == "thread.create" {
                return ["id": creatingThread.id]
            }
            if method == "chat.start" {
                return ["session_id": "session-1"]
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        appState.connectionStatus = .connected

        var sawCreatingState = false
        sync.syncHandler = {
            database.threads = [creatingThread]
            appState.reloadFromDatabase()
            sawCreatingState = appState.threads.first?.status == .creating

            database.threads = [self.makeThread(id: creatingThread.id, projectID: project.id, status: .active)]
            appState.reloadFromDatabase()
        }

        try await appState.createThread(
            projectID: project.id,
            name: "feature-auth",
            sourceType: "new_feature",
            branch: nil
        )

        XCTAssertTrue(sawCreatingState)
        XCTAssertEqual(appState.threads.first?.status, .active)
        XCTAssertEqual(appState.selectedThreadID, creatingThread.id)

        let didAutoStartChat = await waitForCondition {
            connection.requests.contains(where: { $0.method == "chat.start" })
        }
        XCTAssertTrue(didAutoStartChat)

        let chatStart = connection.requests.first(where: { $0.method == "chat.start" })
        XCTAssertEqual(chatStart?.params?["thread_id"] as? String, creatingThread.id)
        XCTAssertEqual(chatStart?.params?["agent_name"] as? String, "opencode")
    }

    func testCreateThreadDoesNotSendRPCBeforeConnectionIsReady() async {
        let connection = MockDaemonConnection(state: .connecting)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        database.projects = [project]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        do {
            try await appState.createThread(
                projectID: project.id,
                name: "feature-auth",
                sourceType: "new_feature",
                branch: nil
            )
            XCTFail("Expected createThread to refuse requests before connection is ready")
        } catch let error as AppStateError {
            guard case .connectionNotReady = error else {
                return XCTFail("Unexpected AppStateError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(connection.requests.isEmpty)
    }

    func testCreateThreadFromRepoContextProvisionsThenCreatesThread() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let remote = Remote(
            id: "remote-1",
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/home/wsl/dev"
        )
        let repo = Repo(
            id: "repo-1",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )
        database.remotes = [remote]
        database.repos = [repo]

        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.lookup":
                return [
                    "exists": false,
                    "is_git_repo": false,
                    "project_id": NSNull(),
                ]
            case "project.clone":
                return ["id": "project-11"]
            case "thread.create":
                return ["id": "thread-11"]
            case "chat.start":
                return ["session_id": "session-11"]
            case "project.list", "thread.list":
                return []
            default:
                throw TestError.missingStub
            }
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        try await appState.createThread(
            repo: repo,
            remote: remote,
            name: "feature-auth",
            sourceType: "new_feature",
            branch: nil
        )

        XCTAssertEqual(Array(connection.requests.prefix(3).map(\.method)), ["project.lookup", "project.clone", "thread.create"])
        XCTAssertTrue(connection.requests.contains(where: { $0.method == "project.list" }))
        XCTAssertEqual(connection.requests[2].params?["project_id"] as? String, "project-11")
        XCTAssertEqual(connection.requests[2].params?["name"] as? String, "feature-auth")
        XCTAssertEqual(database.linkedProjects.count, 1)
        let didAutoStartChat = await waitForCondition {
            connection.requests.contains(where: { $0.method == "chat.start" })
        }
        XCTAssertTrue(didAutoStartChat)
    }

    func testCreateThreadForCrossProjectWorkspaceRejectsRepoLinkedLookupProject() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let remote = Remote(
            id: "remote-1",
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/home/wsl/dev"
        )
        let repo = Repo(
            id: "repo-1",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )
        let existingProject = Project(
            id: "project-1",
            name: repo.name,
            remotePath: "/home/wsl",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remote.id,
            repoId: repo.id
        )
        database.remotes = [remote]
        database.repos = [repo]
        database.projects = [existingProject]

        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.lookup":
                return [
                    "exists": true,
                    "is_git_repo": true,
                    "project_id": existingProject.id,
                ]
            default:
                throw TestError.missingStub
            }
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        do {
            try await appState.createThread(
                repo: .defaultWorkspace,
                remote: remote,
                name: "scratch",
                sourceType: "main_checkout",
                branch: nil
            )
            XCTFail("Expected hijack protection to reject relink")
        } catch let error as AppStateError {
            guard case let .defaultWorkspaceProjectAlreadyLinked(projectID, repoID) = error else {
                return XCTFail("Unexpected AppStateError: \(error)")
            }
            XCTAssertEqual(projectID, existingProject.id)
            XCTAssertEqual(repoID, repo.id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(connection.requests.map(\.method), ["project.lookup"])
        XCTAssertTrue(database.linkedProjects.isEmpty)
    }

    func testCloseThreadRemovesItFromSidebar() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "thread.close" {
                return ["status": "closed"]
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        sync.syncHandler = {
            database.threads = [self.makeThread(id: thread.id, projectID: project.id, status: .closed)]
            appState.reloadFromDatabase()
        }

        XCTAssertEqual(appState.projectsWithThreads.first?.1.count, 1)

        await appState.closeThread(threadID: thread.id)

        XCTAssertEqual(appState.threads.first?.status, .closed)
        XCTAssertEqual(appState.projectsWithThreads.first?.1.count, 0)
    }

    func testHideThreadMarksThreadHiddenInState() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "thread.hide" {
                return ["status": "hidden"]
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        sync.syncHandler = {
            database.threads = [self.makeThread(id: thread.id, projectID: project.id, status: .hidden)]
            appState.reloadFromDatabase()
        }

        await appState.hideThread(threadID: thread.id)

        XCTAssertEqual(appState.threads.first?.status, .hidden)
        XCTAssertEqual(appState.projectsWithThreads.first?.1.count, 1)
    }

    func testReopenThreadRestoresHiddenThreadToActive() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .hidden)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "thread.reopen" {
                return ["id": thread.id]
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        sync.syncHandler = {
            database.threads = [self.makeThread(id: thread.id, projectID: project.id, status: .active)]
            appState.reloadFromDatabase()
        }

        await appState.reopenThread(threadID: thread.id)

        XCTAssertEqual(appState.threads.first?.status, .active)
        XCTAssertEqual(appState.projectsWithThreads.first?.1.count, 1)
    }

    func testCancelCreatingThreadMarksItFailedAndHidesFromSidebar() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .creating)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "thread.cancel" {
                return ["status": "failed"]
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        sync.syncHandler = {
            database.threads = [self.makeThread(id: thread.id, projectID: project.id, status: .failed)]
            appState.reloadFromDatabase()
        }

        XCTAssertEqual(appState.projectsWithThreads.first?.1.count, 1)

        await appState.cancelThreadCreation(threadID: thread.id)

        XCTAssertEqual(appState.threads.first?.status, .failed)
        XCTAssertEqual(appState.projectsWithThreads.first?.1.count, 0)
    }

    func testAddProjectAddsProjectToStateAfterSync() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        connection.requestHandler = { method, _, _ in
            if method == "project.add" {
                return ["id": project.id]
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        sync.syncHandler = {
            database.projects = [project]
            appState.reloadFromDatabase()
        }

        XCTAssertTrue(appState.projects.isEmpty)

        try await appState.addProject(path: "/home/wsl/dev/demo")

        XCTAssertEqual(appState.projects.map(\.id), [project.id])
    }

    func testCloneRepoAddsProjectToStateAfterSync() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        connection.requestHandler = { method, _, _ in
            if method == "project.clone" {
                return ["id": project.id]
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        sync.syncHandler = {
            database.projects = [project]
            appState.reloadFromDatabase()
        }

        XCTAssertTrue(appState.projects.isEmpty)

        try await appState.cloneRepo(url: "https://github.com/org/repo.git", path: "/home/wsl/dev")

        XCTAssertEqual(appState.projects.map(\.id), [project.id])
    }

    func testStopPresetRemovesClosedTabAndSelectsRemainingTab() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, params, _ in
            if method == "preset.start" || method == "preset.stop" {
                if method == "preset.stop" {
                    XCTAssertEqual(params?["thread_id"] as? String, thread.id)
                    XCTAssertEqual(params?["preset"] as? String, "opencode")
                    XCTAssertEqual(params?["session_id"] as? String, "opencode")
                }
                return ["ok": true]
            }
            throw TestError.missingStub
        }
        multiplexer.attachHandler = { _, _, preset in
            let channelID: UInt16 = preset == "terminal" ? 1 : 2
            return RelayEndpoint(
                channelID: channelID,
                threadID: thread.id,
                preset: preset,
                sessionID: preset,
                connectionManager: connection,
                surfaceHost: MockSurfaceHost()
            )
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        await appState.attachSelectedPreset()
        appState.selectedPreset = "opencode"
        await appState.attachSelectedPreset()

        XCTAssertEqual(appState.terminalTabs.compactMap { $0.preset?.name }, ["terminal", "opencode"])

        await appState.stopPreset(named: "opencode")

        XCTAssertEqual(appState.selectedPreset, "terminal")
        XCTAssertEqual(appState.terminalTabs.compactMap { $0.preset?.name }, ["terminal"])
        XCTAssertTrue(connection.requests.contains(where: { $0.method == "preset.stop" }))
    }

    func testStartPresetSendsRPCAndSelectsNewTab() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" { return ["ok": true] }
            throw TestError.missingStub
        }
        multiplexer.attachHandler = { _, _, preset in
            RelayEndpoint(
                channelID: preset == "terminal" ? 1 : 2,
                threadID: thread.id,
                preset: preset,
                sessionID: preset,
                connectionManager: connection,
                surfaceHost: MockSurfaceHost()
            )
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        appState.selectedPreset = "terminal"

        await appState.startPreset(named: "opencode")

        XCTAssertEqual(appState.selectedPreset, "opencode")
        XCTAssertTrue(connection.requests.contains(where: { $0.method == "preset.start" }))
    }

    func testStartPresetAttachesWhenPresetAlreadyRunning() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" {
                throw JSONRPCErrorResponse(code: -32000, message: "preset already running: terminal")
            }
            throw TestError.missingStub
        }
        multiplexer.attachHandler = { threadID, _, preset in
            RelayEndpoint(
                channelID: 7,
                threadID: threadID,
                preset: preset,
                sessionID: preset,
                connectionManager: connection,
                surfaceHost: MockSurfaceHost()
            )
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        appState.connectionStatus = .connected

        await appState.startPreset(named: "terminal")

        XCTAssertEqual(appState.selectedPreset, "terminal")
        XCTAssertEqual(appState.selectedEndpoint?.channelID, 7)
        XCTAssertEqual(multiplexer.attachCallCount, 1)
    }

    func testDefaultTerminalSessionPrefersFirstUnopenedPreset() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "logs", command: "tail -f log", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        appState.selectedPreset = "terminal"

        XCTAssertEqual(TerminalModeActions.defaultTerminalPresetName(appState: appState), "terminal")
    }

    func testAddTerminalSessionSelectsPresetWithoutStartingItTwice() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "dev-server", command: "bun run dev", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        var nextChannelID = 1
        connection.requestHandler = { method, _, _ in
            switch method {
            case "preset.start":
                return ["ok": true]
            case "terminal.attach":
                defer { nextChannelID += 1 }
                return ["channel_id": nextChannelID]
            default:
                throw TestError.missingStub
            }
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        defer { multiplexer.detachAll() }

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()

        let suiteName = "AppStateInteractionBehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tabStateManager = ThreadTabStateManager(defaults: defaults, storageKey: suiteName)

        var terminalSessionIDs = ["terminal"]
        var selectedTerminalSessionID: String? = "terminal"

        TerminalModeActions.addTerminalSession(
            preset: "dev-server",
            appState: appState,
            terminalSessionIDs: Binding(get: { terminalSessionIDs }, set: { terminalSessionIDs = $0 }),
            selectedTerminalSessionIDBinding: Binding(get: { selectedTerminalSessionID }, set: { selectedTerminalSessionID = $0 }),
            tabStateManager: tabStateManager
        )

        let didSelectDevServer = await waitForCondition {
            selectedTerminalSessionID == "dev-server"
        }
        XCTAssertTrue(didSelectDevServer)

        TerminalModeActions.attachSelectedTerminalIfNeeded(
            appState: appState,
            selectedTerminalSessionID: selectedTerminalSessionID,
            threadID: thread.id
        )

        let didAttachDevServer = await waitForCondition(timeout: 2.0) {
            appState.selectedEndpoint?.preset == "dev-server"
        }
        XCTAssertTrue(didAttachDevServer)
        XCTAssertEqual(connection.requests.filter { $0.method == "preset.start" }.count, 1)
        XCTAssertEqual(connection.requests.filter { $0.method == "terminal.attach" }.count, 1)
    }

    func testTerminalDebugSnapshotReflectsPendingAttachAndErrors() async {
        let connection = MockDaemonConnection(state: .connected)
        connection.sessionReady = false
        connection.reconnectAttempt = 2
        connection.lastErrorDescription = "handshake pending"
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" {
                throw JSONRPCErrorResponse(code: -32000, message: "boom")
            }
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        await appState.startPreset(named: "terminal")

        let snapshot = appState.terminalDebugSnapshot(for: "terminal")
        XCTAssertEqual(snapshot?.threadID, thread.id)
        XCTAssertEqual(snapshot?.preset, "terminal")
        XCTAssertEqual(snapshot?.connectionStatus, ConnectionStatus.connected.label)
        XCTAssertEqual(snapshot?.sessionReady, false)
        XCTAssertEqual(snapshot?.reconnectAttempt, 2)
        XCTAssertEqual(snapshot?.pendingAttach, false)
        XCTAssertEqual(snapshot?.endpointAttached, false)
        XCTAssertEqual(snapshot?.connectionLastError, "handshake pending")
        XCTAssertTrue(snapshot?.lastStartError?.contains("boom") == true)
        XCTAssertTrue(snapshot?.summary.contains("sessionReady=false") == true)
        XCTAssertTrue(snapshot?.summary.contains("lastStartError=") == true)
    }

    func testAppDebugSnapshotIncludesSelectionConnectionAndTerminalState() async {
        let connection = MockDaemonConnection(state: .connected)
        connection.sessionReady = true
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        appState.selectedWorkspaceRemoteID = "remote-1"
        appState.selectedPreset = "terminal"
        appState.alertMessage = "attach failed"

        let snapshot = appState.debugSnapshot()

        XCTAssertEqual(snapshot.selectedWorkspaceRemoteID, "remote-1")
        XCTAssertEqual(snapshot.selectedThreadID, thread.id)
        XCTAssertEqual(snapshot.selectedPreset, "terminal")
        XCTAssertEqual(snapshot.connection.status, ConnectionStatus.connected.label)
        XCTAssertEqual(snapshot.connection.sessionReady, true)
        XCTAssertEqual(snapshot.terminal?.preset, "terminal")
        XCTAssertEqual(snapshot.alertMessage, "attach failed")
        XCTAssertTrue(snapshot.summary.contains("selectedThreadID=thread-1"))
        XCTAssertTrue(snapshot.summary.contains("connection.sessionReady=true"))
    }

    func testAppDebugSnapshotIsJSONEncodable() async throws {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        let snapshot = appState.debugSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppStateDebugSnapshot.self, from: data)

        XCTAssertEqual(decoded.selectedThreadID, snapshot.selectedThreadID)
        XCTAssertEqual(decoded.connection.status, snapshot.connection.status)
    }

    func testThreadScopedPresetActionsIgnoreStaleThreadSelection() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
            ]
        )
        let thread1 = makeThread(id: "thread-1", projectID: project.id, status: .active)
        let thread2 = makeThread(id: "thread-2", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread1, thread2]

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" || method == "preset.stop" {
                return ["ok": true]
            }
            throw TestError.missingStub
        }
        multiplexer.attachHandler = { threadID, _, preset in
            RelayEndpoint(
                channelID: 1,
                threadID: threadID,
                preset: preset,
                sessionID: preset,
                connectionManager: connection,
                surfaceHost: MockSurfaceHost()
            )
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        appState.selectedThreadID = thread2.id

        let startStopCountBefore = connection.requests
            .filter { $0.method == "preset.start" || $0.method == "preset.stop" }
            .count
        let attachCountBefore = multiplexer.attachCallCount

        await appState.startPreset(threadID: thread1.id, preset: "opencode")
        await appState.attachPreset(threadID: thread1.id, preset: "opencode")
        await appState.stopPreset(threadID: thread1.id, preset: "opencode")

        XCTAssertEqual(
            connection.requests.filter { $0.method == "preset.start" || $0.method == "preset.stop" }.count,
            startStopCountBefore
        )
        XCTAssertEqual(multiplexer.attachCallCount, attachCountBefore)
        XCTAssertNotEqual(appState.selectedPreset, "opencode")
    }

    func testReloadSelectsTerminalAsDefaultPresetEvenWhenConfigOrderDiffers() {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "logs", command: "tail -f log", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        XCTAssertEqual(appState.presets.map(\.name), ["terminal", "opencode", "logs"])
        XCTAssertEqual(appState.selectedPreset, "terminal")
    }

    func testPresetsPreferTerminalBeforeAnyPresetIsAttached() {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        XCTAssertEqual(appState.selectedPreset, "terminal")
        XCTAssertEqual(appState.presets.map(\.name), ["terminal", "opencode"])
    }

    func testTerminalTabsAlwaysIncludeChatTab() {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        let chatTab = appState.terminalTabs.first { $0.selectionID == TerminalTabModel.chatTabSelectionID }

        XCTAssertNotNil(chatTab)
        if case .chat? = chatTab?.type {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected chat tab type")
        }
    }

    func testStopPresetForChatSelectsFirstTerminalWithoutRPC() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        appState.selectedPreset = TerminalTabModel.chatTabSelectionID

        await appState.stopPreset(named: TerminalTabModel.chatTabSelectionID)

        XCTAssertEqual(appState.selectedPreset, "terminal")
        XCTAssertFalse(connection.requests.contains(where: { $0.method == "preset.stop" }))
    }

    func testReattachingDetachedEndpointDoesNotRestartPreset() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
            ]
        )
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        var nextChannelID = 1
        connection.requestHandler = { method, _, _ in
            switch method {
            case "preset.start":
                return ["ok": true]
            case "terminal.attach":
                defer { nextChannelID += 1 }
                return ["channel_id": nextChannelID]
            default:
                throw TestError.missingStub
            }
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        defer { multiplexer.detachAll() }

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()

        await appState.startPreset(named: "opencode")

        guard let opencodeEndpoint = appState.selectedEndpoint else {
            return XCTFail("Expected opencode endpoint after start")
        }

        appState.selectedPreset = "terminal"
        await appState.attachSelectedPreset()
        let startCountBeforeOpencodeReattach = connection.requests.filter { $0.method == "preset.start" }.count

        opencodeEndpoint.setChannelID(0)

        appState.selectedPreset = "opencode"
        await appState.attachSelectedPreset()

        XCTAssertEqual(appState.selectedEndpoint?.preset, "opencode")
        XCTAssertGreaterThan(appState.selectedEndpoint?.channelID ?? 0, 0)
        XCTAssertEqual(connection.requests.filter { $0.method == "preset.start" }.count, startCountBeforeOpencodeReattach)
    }

    func testAttachSelectedPresetSkipsUnknownPresetWithoutRPC() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = makeProject(id: "project-1")
        let thread = makeThread(id: "thread-1", projectID: project.id, status: .active)
        database.projects = [project]
        database.threads = [thread]

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)
        connection.requests.removeAll()
        appState.selectedPreset = "stale-preset"

        await appState.attachSelectedPreset()

        XCTAssertFalse(connection.requests.contains(where: { $0.method == "preset.start" }))
        XCTAssertNil(appState.selectedEndpoint)
    }

    private func makeAppState(
        connection: MockDaemonConnection,
        database: MockDatabaseManager,
        sync: MockSyncService,
        multiplexer: MockTerminalMultiplexer
    ) -> AppState {
        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()
        return appState
    }

    private func makeProject(id: String) -> Project {
        Project(
            id: id,
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
    }

    private func makeThread(id: String, projectID: String, status: ThreadStatus) -> ThreadModel {
        ThreadModel(
            id: id,
            projectId: projectID,
            name: "feature",
            branch: "feature",
            worktreePath: "/tmp/demo/.threadmill/feature",
            status: status,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 1),
            tmuxSession: "tm_feature",
            portOffset: 0
        )
    }
}
