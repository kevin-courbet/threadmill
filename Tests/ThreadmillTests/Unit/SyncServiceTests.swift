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

    func testSyncFromDaemonUpsertsChatSessionsFromThreadSnapshots() async {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.list", "thread.list":
                return [[String: Any]]()
            case "state.snapshot":
                return [
                    "threads": [
                        [
                            "id": "thread-1",
                            "chat_sessions": [
                                [
                                    "session_id": "session-1",
                                    "agent_type": "opencode",
                                    "title": "Planner",
                                    "status": "ready",
                                    "model_id": "gpt-5",
                                ],
                            ],
                        ],
                    ],
                ]
            default:
                throw TestError.missingStub
            }
        }

        let database = MockDatabaseManager()
        let syncService = SyncService(
            connectionManager: connection,
            databaseManager: database,
            appState: AppState(),
            remoteId: "remote-1"
        )

        await syncService.syncFromDaemon()

        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(database.conversations.first?.threadID, "thread-1")
        XCTAssertEqual(database.conversations.first?.agentSessionID, "session-1")
        XCTAssertEqual(database.conversations.first?.agentType, "opencode")
        XCTAssertEqual(database.conversations.first?.title, "Planner")
    }

    func testSyncFromDaemonDoesNotDeleteExistingChatSessionsMissingFromSnapshot() async {
        let connection = MockDaemonConnection(state: .connected)
        var snapshotCalls = 0
        connection.requestHandler = { method, _, _ in
            switch method {
            case "project.list", "thread.list":
                return [[String: Any]]()
            case "state.snapshot":
                snapshotCalls += 1
                if snapshotCalls == 1 {
                    return [
                        "threads": [
                            [
                                "id": "thread-1",
                                "chat_sessions": [
                                    [
                                        "session_id": "session-1",
                                        "agent_type": "opencode",
                                        "title": "One",
                                        "status": "ready",
                                    ],
                                ],
                            ],
                        ],
                    ]
                }
                return [
                    "threads": [
                        [
                            "id": "thread-1",
                            "chat_sessions": [[String: Any]](),
                        ],
                    ],
                ]
            default:
                throw TestError.missingStub
            }
        }

        let database = MockDatabaseManager()
        let syncService = SyncService(
            connectionManager: connection,
            databaseManager: database,
            appState: AppState(),
            remoteId: "remote-1"
        )

        await syncService.syncFromDaemon()
        XCTAssertEqual(database.conversations.count, 1)

        await syncService.syncFromDaemon()
        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(database.conversations.first?.agentSessionID, "session-1")
    }
}
