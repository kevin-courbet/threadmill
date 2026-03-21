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

    func testProjectsWithThreadsHidesMainCheckoutThreadsForNonWorkspaceProjects() {
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

    func testReposWithThreadsTreatsRemoteWorkspacePathAsCrossProject() {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in NSNull() }

        let remote = Remote(
            id: "remote-1",
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/home/wsl/dev"
        )
        let workspaceProject = Project(
            id: "project-workspace",
            name: "wsl",
            remotePath: "/home/wsl/",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remote.id,
            repoId: nil
        )
        let workspaceThread = ThreadModel(
            id: "thread-workspace",
            projectId: workspaceProject.id,
            name: "scratch",
            branch: "scratch",
            worktreePath: "/home/wsl",
            status: .active,
            sourceType: "main_checkout",
            createdAt: Date(timeIntervalSince1970: 100),
            tmuxSession: "tm_workspace",
            portOffset: 0
        )

        let database = MockDatabaseManager()
        database.remotes = [remote]
        database.projects = [workspaceProject]
        database.threads = [workspaceThread]

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()

        XCTAssertEqual(appState.reposWithThreads.first?.0.id, Repo.defaultWorkspaceID)
        XCTAssertEqual(appState.reposWithThreads.first?.1.map(\.id), ["thread-workspace"])
        XCTAssertTrue(appState.projectsWithThreads.isEmpty)
        XCTAssertTrue(
            database.linkedProjects.contains {
                $0.projectID == workspaceProject.id
                    && $0.repoID == Repo.defaultWorkspaceID
                    && $0.remoteID == remote.id
            }
        )
    }

    func testNormalizeDefaultWorkspaceProjectsSkipsRepoLinkedProjectsAtWorkspacePath() {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in NSNull() }

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
        let project = Project(
            id: "project-workspace-path",
            name: "threadmill",
            remotePath: "/home/wsl/",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remote.id,
            repoId: repo.id
        )
        let thread = ThreadModel(
            id: "thread-repo-linked",
            projectId: project.id,
            name: "feature",
            branch: "feature",
            worktreePath: "/wt/feature",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 100),
            tmuxSession: "tm_feature",
            portOffset: 0
        )

        let database = MockDatabaseManager()
        database.remotes = [remote]
        database.repos = [repo]
        database.projects = [project]
        database.threads = [thread]

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()

        XCTAssertEqual(appState.reposWithThreads.first(where: { $0.0.id == repo.id })?.1.map(\.id), ["thread-repo-linked"])
        XCTAssertEqual(appState.reposWithThreads.first(where: { $0.0.id == Repo.defaultWorkspaceID })?.1.map(\.id), [])
        XCTAssertFalse(database.linkedProjects.contains(where: { $0.projectID == project.id && $0.repoID == Repo.defaultWorkspaceID }))
    }

    func testNormalizeDefaultWorkspaceProjectsSkipsDuplicatePersistenceWhenAlreadyLinked() {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in NSNull() }

        let remote = Remote(
            id: "remote-1",
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/home/wsl/dev"
        )
        let workspaceProject = Project(
            id: "project-workspace",
            name: Repo.defaultWorkspace.name,
            remotePath: "/home/wsl",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)],
            remoteId: remote.id,
            repoId: Repo.defaultWorkspaceID
        )

        let database = MockDatabaseManager()
        database.remotes = [remote]
        database.projects = [workspaceProject]

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )

        appState.reloadFromDatabase()
        appState.reloadFromDatabase()

        XCTAssertTrue(database.linkedProjects.isEmpty)
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

        XCTAssertEqual(appState.reposWithThreads.count, 3)
        XCTAssertEqual(appState.reposWithThreads.first(where: { $0.0.id == Repo.defaultWorkspaceID })?.1.map(\.id), [])
        XCTAssertEqual(appState.reposWithThreads.first(where: { $0.0.id == repoWithThread.id })?.1.map(\.id), ["thread-repo"])
        XCTAssertEqual(appState.reposWithThreads.first(where: { $0.0.id == repoWithoutThread.id })?.1.map(\.id), [])
        XCTAssertEqual(appState.projectsWithThreads.map(\.0.id), ["project-orphan"])
    }
}
