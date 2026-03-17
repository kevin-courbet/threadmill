import XCTest
@testable import Threadmill

@MainActor
final class AppStateRemoteConnectionTests: XCTestCase {
    func testConnectionForSelectedThreadUsesProjectRemote() {
        let remoteA = Remote(id: "remote-a", name: "alpha", host: "alpha", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteB = Remote(id: "remote-b", name: "beta", host: "beta", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")

        let connectionA = MockDaemonConnection(state: .connected)
        let connectionB = MockDaemonConnection(state: .connected)

        let pool = RemoteConnectionPool(remotes: [remoteA, remoteB], connectionFactory: { remote in
            remote.id == remoteA.id ? connectionA : connectionB
        })

        let database = MockDatabaseManager()
        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/home/wsl/dev/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remoteB.id
        )
        let thread = ThreadModel(
            id: "thread-1",
            projectId: project.id,
            name: "feature",
            branch: "feature",
            worktreePath: "/home/wsl/dev/.threadmill/demo/feature",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_feature",
            portOffset: 0
        )
        database.remotes = [remoteA, remoteB]
        database.projects = [project]
        database.threads = [thread]

        let appState = AppState()
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()
        appState.selectedThreadID = thread.id

        let resolved = appState.connectionForSelectedThread()

        XCTAssertTrue((resolved as AnyObject?) === connectionB)
    }

    func testSelectingThreadActivatesAndEnsuresProjectRemoteConnection() async {
        let remoteA = Remote(id: "remote-a", name: "alpha", host: "alpha", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteB = Remote(id: "remote-b", name: "beta", host: "beta", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")

        let connectionA = MockDaemonConnection(state: .connected)
        let connectionB = MockDaemonConnection(state: .disconnected)
        let pool = MockRemoteConnectionPool()
        pool.connections = [
            remoteA.id: connectionA,
            remoteB.id: connectionB,
        ]
        pool.activeRemoteId = remoteA.id

        let database = MockDatabaseManager()
        let projectA = Project(
            id: "project-a",
            name: "alpha",
            remotePath: "/home/wsl/dev/alpha",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remoteA.id
        )
        let projectB = Project(
            id: "project-b",
            name: "beta",
            remotePath: "/home/wsl/dev/beta",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remoteB.id
        )
        let threadA = ThreadModel(
            id: "thread-a",
            projectId: projectA.id,
            name: "feature-a",
            branch: "feature-a",
            worktreePath: "/home/wsl/dev/.threadmill/alpha/feature-a",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 1),
            tmuxSession: "tm_feature_a",
            portOffset: 0
        )
        let threadB = ThreadModel(
            id: "thread-b",
            projectId: projectB.id,
            name: "feature-b",
            branch: "feature-b",
            worktreePath: "/home/wsl/dev/.threadmill/beta/feature-b",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 2),
            tmuxSession: "tm_feature_b",
            portOffset: 0
        )
        database.remotes = [remoteA, remoteB]
        database.projects = [projectA, projectB]
        database.threads = [threadA, threadB]

        let appState = AppState()
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()
        appState.selectedThreadID = threadB.id

        let didActivate = await waitForCondition {
            pool.activeRemoteId == remoteB.id
                && pool.activatedRemoteIDs.last == remoteB.id
                && pool.ensuredRemoteIDs.last == remoteB.id
        }

        XCTAssertTrue(didActivate)
        XCTAssertEqual(connectionB.startCallCount, 1)
    }

    func testCreateThreadSyncsTargetProjectRemote() async throws {
        let remoteA = Remote(id: "remote-a", name: "alpha", host: "alpha", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteB = Remote(id: "remote-b", name: "beta", host: "beta", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")

        let connectionA = MockDaemonConnection(state: .connected)
        let connectionB = MockDaemonConnection(state: .connected)
        connectionB.requestHandler = { method, _, _ in
            switch method {
            case "thread.create":
                return ["id": "thread-b"]
            case "state.snapshot":
                return [
                    "state_version": 5,
                    "projects": [[
                        "id": "project-b",
                        "name": "beta",
                        "path": "/home/wsl/dev/beta",
                        "default_branch": "main",
                        "remote_id": remoteB.id,
                    ]],
                    "threads": [[
                        "id": "thread-b",
                        "project_id": "project-b",
                        "name": "feature-b",
                        "branch": "feature-b",
                        "worktree_path": "/home/wsl/dev/.threadmill/beta/feature-b",
                        "status": "active",
                        "source_type": "new_feature",
                        "created_at": "2026-03-07T00:00:00Z",
                        "tmux_session": "tm_feature_b",
                        "port_offset": 0,
                    ]],
                ]
            default:
                throw TestError.missingStub
            }
        }

        let pool = MockRemoteConnectionPool()
        pool.connections = [remoteA.id: connectionA, remoteB.id: connectionB]
        pool.activeRemoteId = remoteA.id

        let database = MockDatabaseManager()
        database.remotes = [remoteA, remoteB]
        database.projects = [
            Project(
                id: "project-b",
                name: "beta",
                remotePath: "/home/wsl/dev/beta",
                defaultBranch: "main",
                presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
                remoteId: remoteB.id
            )
        ]

        let appState = AppState()
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()

        try await appState.createThread(projectID: "project-b", name: "feature-b", sourceType: "new_feature", branch: nil)

        XCTAssertEqual(database.replaceAllFromDaemonRemoteIDs.last, remoteB.id)
        XCTAssertEqual(connectionB.requests.map(\.method), ["thread.create", "state.snapshot"])
    }

    func testReloadFromDatabaseReconcilesRemoteConnectionPool() {
        let remoteA = Remote(id: "remote-a", name: "alpha", host: "alpha", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteAUpdated = Remote(id: "remote-a", name: "alpha", host: "alpha-new", daemonPort: 20001, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteB = Remote(id: "remote-b", name: "beta", host: "beta", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteC = Remote(id: "remote-c", name: "charlie", host: "charlie", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")

        let database = MockDatabaseManager()
        database.remotes = [remoteA, remoteB]

        let pool = MockRemoteConnectionPool()
        pool.connections = [
            remoteA.id: MockDaemonConnection(state: .connected),
            remoteB.id: MockDaemonConnection(state: .connected),
        ]

        let appState = AppState()
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )

        appState.reloadFromDatabase()
        pool.addedRemotes.removeAll()
        pool.updatedRemotes.removeAll()
        pool.removedRemoteIDs.removeAll()

        database.remotes = [remoteAUpdated, remoteC]
        appState.reloadFromDatabase()

        XCTAssertEqual(pool.removedRemoteIDs, [remoteB.id])
        XCTAssertEqual(pool.updatedRemotes.last?.id, remoteAUpdated.id)
        XCTAssertEqual(pool.addedRemotes.last?.id, remoteC.id)
    }

    func testSessionHelloBaselineIsTrackedPerRemote() async {
        let remoteA = Remote(id: "remote-a", name: "alpha", host: "alpha", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteB = Remote(id: "remote-b", name: "beta", host: "beta", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")

        let database = MockDatabaseManager()
        let pool = MockRemoteConnectionPool()
        let sync = MockSyncService()

        let projectA = Project(
            id: "project-a",
            name: "alpha",
            remotePath: "/home/wsl/dev/alpha",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remoteA.id
        )
        let projectB = Project(
            id: "project-b",
            name: "beta",
            remotePath: "/home/wsl/dev/beta",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remoteB.id
        )
        let threadA = ThreadModel(
            id: "thread-a",
            projectId: projectA.id,
            name: "feature-a",
            branch: "feature-a",
            worktreePath: "/home/wsl/dev/.threadmill/alpha/feature-a",
            status: .creating,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_feature_a",
            portOffset: 0
        )

        database.remotes = [remoteA, remoteB]
        database.projects = [projectA, projectB]
        database.threads = [threadA]

        let appState = AppState()
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: sync,
            multiplexer: MockTerminalMultiplexer(),
            usesConnectionScopedSyncServices: true
        )
        appState.reloadFromDatabase()

        appState.handleDaemonEvent(method: "session.hello", params: ["state_version": 5], remoteID: remoteA.id)
        appState.handleDaemonEvent(method: "session.hello", params: ["state_version": 0], remoteID: remoteB.id)
        appState.handleDaemonEvent(
            method: "state.delta",
            params: [
                "state_version": 6,
                "operations": [[
                    "type": "thread.status_changed",
                    "thread_id": threadA.id,
                    "new": "active",
                ]],
            ],
            remoteID: remoteA.id
        )

        XCTAssertEqual(appState.threads.first?.status, .active)
        XCTAssertEqual(sync.syncCount, 0)
    }

    func testResyncRequirementIsTrackedPerRemote() async {
        let remoteA = Remote(id: "remote-a", name: "alpha", host: "alpha", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")
        let remoteB = Remote(id: "remote-b", name: "beta", host: "beta", daemonPort: 19990, useSSHTunnel: true, cloneRoot: "/home/wsl/dev")

        let database = MockDatabaseManager()
        let pool = MockRemoteConnectionPool()
        let sync = MockSyncService()
        let connectionA = MockDaemonConnection(state: .connected)
        let connectionB = MockDaemonConnection(state: .connected)

        let projectA = Project(
            id: "project-a",
            name: "alpha",
            remotePath: "/home/wsl/dev/alpha",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remoteA.id
        )
        let projectB = Project(
            id: "project-b",
            name: "beta",
            remotePath: "/home/wsl/dev/beta",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remoteB.id
        )
        let threadA = ThreadModel(
            id: "thread-a",
            projectId: projectA.id,
            name: "feature-a",
            branch: "feature-a",
            worktreePath: "/home/wsl/dev/.threadmill/alpha/feature-a",
            status: .creating,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_feature_a",
            portOffset: 0
        )

        database.remotes = [remoteA, remoteB]
        database.projects = [projectA, projectB]
        database.threads = [threadA]
        pool.connections = [remoteA.id: connectionA, remoteB.id: connectionB]
        connectionB.requestHandler = { method, _, _ in
            guard method == "state.snapshot" else {
                throw TestError.missingStub
            }
            return [
                "state_version": 1,
                "projects": [
                    [
                        "id": projectA.id,
                        "name": projectA.name,
                        "path": projectA.remotePath,
                        "default_branch": projectA.defaultBranch,
                        "remote_id": remoteA.id,
                    ],
                    [
                        "id": projectB.id,
                        "name": projectB.name,
                        "path": projectB.remotePath,
                        "default_branch": projectB.defaultBranch,
                        "remote_id": remoteB.id,
                    ],
                ],
                "threads": [[
                    "id": threadA.id,
                    "project_id": projectA.id,
                    "name": threadA.name,
                    "branch": threadA.branch,
                    "worktree_path": threadA.worktreePath,
                    "status": "creating",
                    "source_type": threadA.sourceType,
                    "created_at": "2026-03-07T00:00:00Z",
                    "tmux_session": threadA.tmuxSession,
                    "port_offset": threadA.portOffset ?? 0,
                ]],
            ]
        }

        let appState = AppState()
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: sync,
            multiplexer: MockTerminalMultiplexer(),
            usesConnectionScopedSyncServices: true
        )
        appState.reloadFromDatabase()

        appState.handleDaemonEvent(method: "session.hello", params: ["state_version": 5], remoteID: remoteA.id)
        appState.handleDaemonEvent(method: "session.hello", params: ["state_version": 0], remoteID: remoteB.id)
        appState.handleDaemonEvent(method: "state.delta", params: ["state_version": "bad"], remoteID: remoteB.id)

        let didScheduleRemoteBSync = await waitForCondition {
            connectionB.requests.contains(where: { $0.method == "state.snapshot" })
        }
        XCTAssertTrue(didScheduleRemoteBSync)

        appState.handleDaemonEvent(
            method: "state.delta",
            params: [
                "state_version": 6,
                "operations": [[
                    "type": "thread.status_changed",
                    "thread_id": threadA.id,
                    "new": "active",
                ]],
            ],
            remoteID: remoteA.id
        )

        XCTAssertEqual(appState.threads.first?.status, .active)
        XCTAssertEqual(connectionA.requests.filter { $0.method == "state.snapshot" }.count, 0)
    }
}
