import XCTest
@testable import Threadmill

@MainActor
final class AppStateInteractionBehaviorTests: XCTestCase {
    func testCreateThreadTransitionsFromCreatingToActive() async throws {
        let connection = MockDaemonConnection(state: .connected)
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
            throw TestError.missingStub
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

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

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" || method == "preset.stop" {
                return ["ok": true]
            }
            throw TestError.missingStub
        }
        multiplexer.attachHandler = { _, preset in
            let channelID: UInt16 = preset == "terminal" ? 1 : 2
            return RelayEndpoint(
                channelID: channelID,
                threadID: thread.id,
                preset: preset,
                connectionManager: connection,
                surfaceHost: MockSurfaceHost()
            )
        }

        let appState = makeAppState(connection: connection, database: database, sync: sync, multiplexer: multiplexer)

        await appState.attachSelectedPreset()
        appState.selectedPreset = "opencode"
        await appState.attachSelectedPreset()

        XCTAssertEqual(appState.terminalTabs.map(\.preset.name), ["terminal", "opencode"])

        await appState.stopPreset(named: "opencode")

        XCTAssertEqual(appState.selectedPreset, "terminal")
        XCTAssertEqual(appState.terminalTabs.map(\.preset.name), ["terminal"])
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
        multiplexer.attachHandler = { _, preset in
            RelayEndpoint(
                channelID: preset == "terminal" ? 1 : 2,
                threadID: thread.id,
                preset: preset,
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

        private func makeAppState(
        connection: MockDaemonConnection,
        database: MockDatabaseManager,
        sync: MockSyncService,
        multiplexer: MockTerminalMultiplexer
    ) -> AppState {
        let appState = AppState()
        appState.configure(
            connectionManager: connection,
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
