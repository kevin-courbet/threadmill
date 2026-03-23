import XCTest
@testable import Threadmill

@MainActor
final class AppStateAttachAfterConnectTests: XCTestCase {
    func testReloadFromDatabaseAfterPresetSyncTriggersAttachWhenConnected() async {
        let restoreTabState = saveThreadTabState(
            threadID: "thread-1",
            selectedMode: TabItem.terminal.id,
            terminalSessionIDs: ["terminal"],
            selectedTerminalSessionID: "terminal"
        )
        defer { restoreTabState() }

        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

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
        database.projects = [
            Project(
                id: "proj-1",
                name: "test-project",
                remotePath: "/test",
                defaultBranch: "main",
                presets: []
            )
        ]
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
        appState.selectedPreset = "terminal"
        appState.connectionStatus = .connected
        XCTAssertNil(appState.selectedEndpoint)

        database.projects = [
            Project(
                id: "proj-1",
                name: "test-project",
                remotePath: "/test",
                defaultBranch: "main",
                presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
            )
        ]

        appState.reloadFromDatabase()

        let attached = await waitForCondition(timeout: 2.0) {
            appState.selectedEndpoint != nil
        }
        XCTAssertTrue(attached, "selectedEndpoint should be set after presets become available during sync")
    }

    func testConnectionStatusChangeToConnectedTriggersAttach() async {
        let restoreTabState = saveThreadTabState(
            threadID: "thread-1",
            selectedMode: TabItem.terminal.id,
            terminalSessionIDs: ["terminal"],
            selectedTerminalSessionID: "terminal"
        )
        defer { restoreTabState() }

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

    func testAttachSelectedPresetKeepsTerminalSessionIDWhenValidatingDaemonPresetName() async {
        let restoreTabState = saveThreadTabState(
            threadID: "thread-1",
            selectedMode: TabItem.terminal.id,
            terminalSessionIDs: ["terminal-1"],
            selectedTerminalSessionID: "terminal-1"
        )
        defer { restoreTabState() }

        let connection = MockDaemonConnection(state: .connected)
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
        multiplexer.attachHandler = { _, sessionID, preset in
            RelayEndpoint(
                channelID: 1,
                threadID: "thread-1",
                preset: sessionID,
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
        appState.selectedPreset = "terminal-1"

        await appState.attachSelectedPreset()

        XCTAssertEqual(appState.selectedPreset, "terminal-1")
        XCTAssertEqual(appState.selectedEndpoint?.preset, "terminal-1")
    }

    func testScheduleAttachSelectedPresetCancelsPreviousRetryTask() {
        let restoreTabState = saveThreadTabState(
            threadID: "thread-1",
            selectedMode: TabItem.terminal.id,
            terminalSessionIDs: ["terminal-1"],
            selectedTerminalSessionID: "terminal-1"
        )
        defer { restoreTabState() }

        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        database.projects = [
            Project(
                id: "proj-1",
                name: "test-project",
                remotePath: "/test",
                defaultBranch: "main",
                presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
            )
        ]
        database.threads = [
            ThreadModel(
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
        ]

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()
        appState.selectedPreset = "terminal-1"

        appState.scheduleAttachSelectedPreset()
        let firstTask = appState.pendingScheduledAttachTask
        appState.scheduleAttachSelectedPreset()

        XCTAssertNotNil(firstTask)
        XCTAssertTrue(firstTask?.isCancelled == true)
    }

    func testShutdownStopsStatsPolling() async {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

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
    }

    private func saveThreadTabState(
        threadID: String,
        selectedMode: String,
        terminalSessionIDs: [String],
        selectedTerminalSessionID: String?
    ) -> () -> Void {
        let defaults = UserDefaults.standard
        let storageKey = "threadmill.thread-tab-state"
        let previousValue = defaults.data(forKey: storageKey)
        defaults.removeObject(forKey: storageKey)

        let manager = ThreadTabStateManager()
        manager.setSelectedMode(selectedMode, threadID: threadID)
        manager.setTerminalSessionIDs(terminalSessionIDs, threadID: threadID)
        manager.setSelectedSessionID(selectedTerminalSessionID, modeID: TabItem.terminal.id, threadID: threadID)

        return {
            if let previousValue {
                defaults.set(previousValue, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }
    }
}
