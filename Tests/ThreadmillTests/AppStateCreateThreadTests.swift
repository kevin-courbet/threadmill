import XCTest
@testable import Threadmill

@MainActor
final class AppStateCreateThreadTests: XCTestCase {
    func testCreateThreadSendsThreadCreateMethodAndParamsForNewFeature() async throws {
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

        try await appState.createThread(
            projectID: "proj-1",
            name: "feature-auth",
            sourceType: "new_feature",
            branch: nil
        )

        XCTAssertEqual(connection.requests.count, 1)
        XCTAssertEqual(connection.requests[0].method, "thread.create")
        XCTAssertEqual(connection.requests[0].params?["project_id"] as? String, "proj-1")
        XCTAssertEqual(connection.requests[0].params?["name"] as? String, "feature-auth")
        XCTAssertEqual(connection.requests[0].params?["source_type"] as? String, "new_feature")
        XCTAssertNil(connection.requests[0].params?["branch"])
    }
}
