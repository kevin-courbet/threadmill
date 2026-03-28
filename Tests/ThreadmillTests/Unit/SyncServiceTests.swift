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
            case "state.snapshot":
                return ["chat_sessions": [[String: Any]]()]
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

        XCTAssertEqual(connection.requests.map(\.method), ["project.list", "thread.list", "state.snapshot"])
        XCTAssertEqual(database.replaceAllFromDaemonRemoteIDs, ["remote-42"])
    }

    func testSyncFromDaemonPopulatesAgentStatusFromSnapshot() async {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.list", "thread.list":
                return [[String: Any]]()
            case "state.snapshot":
                return [
                    "chat_sessions": [
                        [
                            "thread_id": "thread-1",
                            "agent_status": [
                                "status": "busy",
                                "worker_count": 2,
                                "last_update_time": "2026-03-28T12:00:00Z",
                            ],
                        ],
                    ],
                ]
            default:
                throw TestError.missingStub
            }
        }

        let appState = AppState()
        let syncService = SyncService(
            connectionManager: connection,
            databaseManager: MockDatabaseManager(),
            appState: appState,
            remoteId: "remote-1"
        )

        await syncService.syncFromDaemon()

        XCTAssertEqual(appState.agentStatus["thread-1"]?.workerCount, 2)
        XCTAssertEqual(appState.agentStatus["thread-1"]?.status, .busy(workerCount: 2))
    }
}
