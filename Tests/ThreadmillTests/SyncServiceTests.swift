import XCTest
@testable import Threadmill

@MainActor
final class SyncServiceTests: XCTestCase {
    func testSyncFromDaemonUsesConfiguredRemoteID() async {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            switch method {
            case "state.snapshot":
                return [
                    "state_version": 42,
                    "projects": [[String: Any]](),
                    "threads": [[String: Any]](),
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
            remoteId: "remote-42"
        )

        await syncService.syncFromDaemon()

        XCTAssertEqual(connection.requests.map(\.method), ["state.snapshot"])
        XCTAssertEqual(database.replaceAllFromDaemonRemoteIDs, ["remote-42"])
    }

    func testSyncFromDaemonDoesNotReplaceCacheWhenSnapshotProjectsAreMalformed() async {
        let existingProject = Project(
            id: "project-1",
            name: "alpha",
            remotePath: "/tmp/alpha",
            defaultBranch: "main",
            presets: [],
            remoteId: "remote-42"
        )
        let existingThread = ThreadModel(
            id: "thread-1",
            projectId: existingProject.id,
            name: "feature-a",
            branch: "feature-a",
            worktreePath: "/tmp/alpha/feature-a",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 0),
            tmuxSession: "tm_feature_a",
            portOffset: 0
        )

        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            switch method {
            case "state.snapshot":
                return [
                    "state_version": 42,
                    "projects": ["invalid": true],
                    "threads": [[String: Any]](),
                ]
            default:
                throw TestError.missingStub
            }
        }

        let database = MockDatabaseManager()
        database.projects = [existingProject]
        database.threads = [existingThread]
        let syncService = SyncService(
            connectionManager: connection,
            databaseManager: database,
            appState: AppState(),
            remoteId: "remote-42"
        )

        await syncService.syncFromDaemon()

        XCTAssertEqual(database.projects.map(\.id), [existingProject.id])
        XCTAssertEqual(database.threads.map(\.id), [existingThread.id])
        XCTAssertTrue(database.replaceAllFromDaemonRemoteIDs.isEmpty)
    }
}
