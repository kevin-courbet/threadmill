import XCTest
@testable import Threadmill

@MainActor
final class AppStateAttachAfterConnectTests: XCTestCase {
    func testConnectionStatusChangeToConnectedTriggersAttach() async {
        let connection = MockDaemonConnection(state: .disconnected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "proj-1",
            name: "test-project",
            remotePath: "/test",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        let thread = ThreadModel(
            id: "thread-1",
            projectId: "proj-1",
            name: "active-thread",
            branch: "main",
            worktreePath: "/wt",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_test",
            portOffset: 0
        )
        database.projects = [project]
        database.threads = [thread]

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" { return ["ok": true] as [String: Any] }
            throw TestError.missingStub
        }
        multiplexer.attachHandler = { _, _ in
            RelayEndpoint(
                channelID: 1,
                threadID: "thread-1",
                preset: "terminal",
                connectionManager: connection,
                surfaceHost: MockSurfaceHost()
            )
        }

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()

        // Endpoint should be nil — not connected yet
        XCTAssertNil(appState.selectedEndpoint)

        // Simulate connection becoming established (what AppDelegate.onConnected does)
        connection.state = .connected
        appState.connectionStatus = .connected

        // The attach should be triggered automatically by the status change
        let attached = await waitForCondition(timeout: 2.0) {
            appState.selectedEndpoint != nil
        }
        XCTAssertTrue(attached, "selectedEndpoint should be set after connectionStatus changes to .connected")
    }
}
