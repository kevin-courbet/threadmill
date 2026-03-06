import XCTest
@testable import Threadmill

@MainActor
final class AppStateProjectsWithThreadsTests: XCTestCase {
    func testProjectsWithThreadsExcludesClosedAndFailedThreads() {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in NSNull() }

        let project = Project(
            id: "proj-1",
            name: "test-project",
            remotePath: "/test",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        let activeThread = ThreadModel(
            id: "thread-active",
            projectId: "proj-1",
            name: "active",
            branch: "main",
            worktreePath: "/wt/active",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 100),
            tmuxSession: "tm_active",
            portOffset: 0
        )
        let closedThread = ThreadModel(
            id: "thread-closed",
            projectId: "proj-1",
            name: "closed",
            branch: "main",
            worktreePath: "/wt/closed",
            status: .closed,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 200),
            tmuxSession: "tm_closed",
            portOffset: 20
        )
        let failedThread = ThreadModel(
            id: "thread-failed",
            projectId: "proj-1",
            name: "failed",
            branch: "main",
            worktreePath: "/wt/failed",
            status: .failed,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 300),
            tmuxSession: "tm_failed",
            portOffset: 40
        )

        let database = MockDatabaseManager()
        database.projects = [project]
        database.threads = [activeThread, closedThread, failedThread]

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()

        let visibleThreadIDs = appState.projectsWithThreads.first?.1.map(\.id)

        XCTAssertEqual(visibleThreadIDs, ["thread-active"])
    }

    func testProjectsWithThreadsHidesMainCheckoutThreads() {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in NSNull() }

        let project = Project(
            id: "proj-1",
            name: "test-project",
            remotePath: "/test",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        let featureThread = ThreadModel(
            id: "thread-feature",
            projectId: "proj-1",
            name: "feature",
            branch: "feature",
            worktreePath: "/wt/feature",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 100),
            tmuxSession: "tm_feature",
            portOffset: 0
        )
        let mainCheckoutThread = ThreadModel(
            id: "thread-main",
            projectId: "proj-1",
            name: "main",
            branch: "main",
            worktreePath: "/wt/main",
            status: .active,
            sourceType: "main_checkout",
            createdAt: Date(timeIntervalSince1970: 200),
            tmuxSession: "tm_main",
            portOffset: 20
        )

        let database = MockDatabaseManager()
        database.projects = [project]
        database.threads = [featureThread, mainCheckoutThread]

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()

        let visibleThreadIDs = appState.projectsWithThreads.first?.1.map(\.id)

        XCTAssertEqual(visibleThreadIDs, ["thread-feature"])
    }

    func testReposWithThreadsGroupsByRepoAndIncludesEmptyRepos() {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in NSNull() }

        let repoWithThread = Repo(
            id: "repo-1",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )
        let repoWithoutThread = Repo(
            id: "repo-2",
            owner: "anomalyco",
            name: "spindle",
            fullName: "anomalyco/spindle",
            cloneURL: "git@github.com:anomalyco/spindle.git",
            defaultBranch: "main",
            isPrivate: false,
            cachedAt: Date(timeIntervalSince1970: 2)
        )

        let linkedProject = Project(
            id: "project-linked",
            name: "threadmill",
            remotePath: "/home/wsl/dev/threadmill",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: nil,
            repoId: repoWithThread.id
        )
        let orphanProject = Project(
            id: "project-orphan",
            name: "legacy",
            remotePath: "/home/wsl/dev/legacy",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: nil,
            repoId: nil
        )

        let repoThread = ThreadModel(
            id: "thread-repo",
            projectId: linkedProject.id,
            name: "feature-repo",
            branch: "feature/repo",
            worktreePath: "/wt/repo",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 300),
            tmuxSession: "tm_repo",
            portOffset: 0
        )
        let orphanThread = ThreadModel(
            id: "thread-orphan",
            projectId: orphanProject.id,
            name: "feature-orphan",
            branch: "feature/orphan",
            worktreePath: "/wt/orphan",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 200),
            tmuxSession: "tm_orphan",
            portOffset: 20
        )

        let database = MockDatabaseManager()
        database.repos = [repoWithThread, repoWithoutThread]
        database.projects = [linkedProject, orphanProject]
        database.threads = [repoThread, orphanThread]

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()

        XCTAssertEqual(appState.reposWithThreads.count, 2)
        XCTAssertEqual(appState.reposWithThreads.first(where: { $0.0.id == repoWithThread.id })?.1.map(\.id), ["thread-repo"])
        XCTAssertEqual(appState.reposWithThreads.first(where: { $0.0.id == repoWithoutThread.id })?.1.map(\.id), [])
        XCTAssertEqual(appState.projectsWithThreads.map(\.0.id), ["project-orphan"])
    }
}
