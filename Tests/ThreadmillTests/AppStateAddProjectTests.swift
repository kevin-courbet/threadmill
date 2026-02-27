import XCTest
@testable import Threadmill

@MainActor
final class AppStateAddProjectTests: XCTestCase {
    func testAddProjectSendsProjectAddMethodAndParams() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { _, _, _ in NSNull() }

        let database = MockDatabaseManager()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let appState = AppState()
        appState.configure(
            connectionManager: connection,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()

        try await appState.addProject(path: "/home/wsl/dev/test-project")

        XCTAssertEqual(connection.requests.count, 1)
        XCTAssertEqual(connection.requests[0].method, "project.add")
        XCTAssertEqual(connection.requests[0].params?["path"] as? String, "/home/wsl/dev/test-project")
    }
}
