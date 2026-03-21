import XCTest
@testable import Threadmill

@MainActor
final class AppStateRemoveProjectTests: XCTestCase {
    func testRemoveProjectRemovesProjectFromAppState() async {
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
        database.projects = [project]

        connection.requestHandler = { method, _, _ in
            if method == "project.remove" {
                return ["removed": true]
            }
            throw TestError.missingStub
        }

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()

        sync.syncHandler = {
            database.projects = []
            appState.reloadFromDatabase()
        }

        XCTAssertEqual(appState.projects.count, 1)

        await appState.removeProject(projectID: "project-1")

        XCTAssertTrue(appState.projects.isEmpty)
    }
}
