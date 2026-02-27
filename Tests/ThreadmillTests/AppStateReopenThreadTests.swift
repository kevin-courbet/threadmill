import XCTest
@testable import Threadmill

@MainActor
final class AppStateReopenThreadTests: XCTestCase {
    func testReopenThreadSendsThreadReopenMethodAndParams() async {
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

        await appState.reopenThread(threadID: "thread-1")

        XCTAssertEqual(connection.requests.count, 1)
        XCTAssertEqual(connection.requests[0].method, "thread.reopen")
        XCTAssertEqual(connection.requests[0].params?["thread_id"] as? String, "thread-1")
    }
}
