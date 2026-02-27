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
            connectionManager: connection,
            databaseManager: database,
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )
        appState.reloadFromDatabase()

        let visibleThreadIDs = appState.projectsWithThreads.first?.1.map(\.id)

        XCTAssertEqual(visibleThreadIDs, ["thread-active"])
    }
}
