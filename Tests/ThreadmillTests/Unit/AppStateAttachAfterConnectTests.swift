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
        multiplexer.attachHandler = { _, _, _ in
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

    func testShutdownStopsStatsPolling() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let openCodeClient = MockOpenCodeClient()

        connection.requestHandler = { method, _, _ in
            if method == "system.stats" {
                return [:]
            }
            throw TestError.missingStub
        }

        let appState = AppState(statsPollingEnabled: true, statsRefreshInterval: 0.05)
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer,
            openCodeClient: openCodeClient
        )

        appState.connectionStatus = .connected

        let didPoll = await waitForCondition(timeout: 1.0) {
            connection.requests.contains { $0.method == "system.stats" }
        }
        XCTAssertTrue(didPoll)

        let requestCountBeforeShutdown = connection.requests.filter { $0.method == "system.stats" }.count
        appState.shutdown()

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(connection.requests.filter { $0.method == "system.stats" }.count, requestCountBeforeShutdown)
        XCTAssertEqual(openCodeClient.invalidateCallCount, 1)
    }
}
