import XCTest
@testable import Threadmill

@MainActor
final class SyncServiceTests: XCTestCase {
    func testSyncFromDaemonUsesConfiguredRemoteID() async {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.list", "thread.list":
                return [[String: Any]]()
            default:
                throw TestError.missingStub
            }
        }

        let database = MockDatabaseManager()
        let syncService = SyncService(
            connectionManager: connection,
            databaseManager: database,
            appState: AppState(),
            remoteId: "remote-42"
        )

        await syncService.syncFromDaemon()

        XCTAssertEqual(connection.requests.map(\.method), ["project.list", "thread.list"])
        XCTAssertEqual(database.replaceAllFromDaemonRemoteIDs, ["remote-42"])
    }
}
