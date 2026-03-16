import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class AppStateEventHandlingTests: XCTestCase {
    func testHandleDaemonEventStatusChangedUpdatesState() {
        let appState = makeConfiguredAppState()
        appState.threads = [
            ThreadModel(
                id: "thread-1",
                projectId: "project-1",
                name: "Demo",
                branch: "main",
                worktreePath: "/tmp/demo",
                status: .creating,
                sourceType: "branch",
                createdAt: Date(),
                tmuxSession: ""
            )
        ]

        appState.handleDaemonEvent(method: "thread.status_changed", params: ["thread_id": "thread-1", "new": "active"])

        XCTAssertEqual(appState.threads.first?.status, .active)
    }

    func testHandleDaemonEventThreadCreatedTriggersSync() async {
        let (_, _, syncService, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(method: "thread.created", params: ["thread_id": "thread-2"])

        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testHandleDaemonEventThreadRemovedTriggersSync() async {
        let (_, _, syncService, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(method: "thread.removed", params: ["thread_id": "thread-2"])

        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testHandleDaemonEventUnknownEventDoesNotCrash() async {
        let (_, _, syncService, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(method: "thread.unknown", params: ["foo": "bar"])
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(syncService.syncCount, 0)
    }

    func testHandleDaemonEventCloneProgressDoesNotTriggerSync() async {
        let (_, _, syncService, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(
            method: "project.clone_progress",
            params: [
                "thread_id": "clone-1",
                "step": "fetching",
                "message": "Receiving objects",
            ]
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(syncService.syncCount, 0)
    }

    func testHandleStateDeltaStatusOperationUpdatesStateWithoutSync() async {
        let (_, _, syncService, _, appState) = makeConfiguredAppStateWithDoubles()
        appState.threads = [makeThread(id: "thread-1", status: .creating)]

        appState.handleDaemonEvent(
            method: "state.delta",
            params: [
                "state_version": 5,
                "operations": [
                    [
                        "op_id": "op-1",
                        "type": "thread.status_changed",
                        "thread_id": "thread-1",
                        "old": "creating",
                        "new": "active",
                    ],
                ],
            ]
        )

        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(appState.threads.first?.status, .active)
        XCTAssertEqual(syncService.syncCount, 0)
    }

    func testHandleStateDeltaUnknownOperationSchedulesSync() async {
        let (_, _, syncService, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(
            method: "state.delta",
            params: [
                "state_version": 7,
                "operations": [
                    [
                        "op_id": "op-2",
                        "type": "thread.upsert",
                        "thread": ["id": "thread-1"],
                    ],
                ],
            ]
        )

        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testPresetOutputEventDoesNotTriggerSync() async {
        let (_, _, syncService, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(
            method: "preset.output",
            params: [
                "thread_id": "thread-1",
                "preset": "dev-server",
                "stream": "stderr",
                "chunk": "crash stack",
            ]
        )

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(syncService.syncCount, 0)
    }

    func testAttachSkipsCreatingAndFailedThreads() async {
        let (connection, _, _, multiplexer, appState) = makeConfiguredAppStateWithDoubles()
        connection.requestHandler = { _, _, _ in NSNull() }

        appState.threads = [makeThread(id: "thread-1", status: .creating)]
        appState.selectedThreadID = "thread-1"
        appState.selectedPreset = "terminal"

        await appState.attachSelectedPreset()
        XCTAssertEqual(connection.requests.count, 0)
        XCTAssertEqual(multiplexer.attachCallCount, 0)

        appState.threads[0].status = .failed
        await appState.attachSelectedPreset()
        XCTAssertEqual(connection.requests.count, 0)
        XCTAssertEqual(multiplexer.attachCallCount, 0)
    }

    func testAttachPermanentTmuxErrorStopsRetry() async {
        let (connection, _, _, multiplexer, appState) = makeConfiguredAppStateWithDoubles()
        appState.projects = [makeProject(id: "project-1")]
        appState.threads = [makeThread(id: "thread-1", status: .active)]
        appState.selectedThreadID = "thread-1"
        appState.selectedPreset = "terminal"

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" {
                return NSNull()
            }
            throw TestError.forcedFailure
        }
        multiplexer.attachHandler = { _, _ in
            throw JSONRPCErrorResponse(code: -1, message: "tmux session not running: tm_thread_1")
        }

        await appState.attachSelectedPreset()
        await appState.attachSelectedPreset()

        XCTAssertEqual(multiplexer.attachCallCount, 1)
        XCTAssertEqual(connection.requests.filter { $0.method == "preset.start" }.count, 1)
    }

    func testAttachPermanentTmuxErrorStopsRetryUsingStructuredKind() async {
        let (connection, _, _, multiplexer, appState) = makeConfiguredAppStateWithDoubles()
        appState.projects = [makeProject(id: "project-1")]
        appState.threads = [makeThread(id: "thread-1", status: .active)]
        appState.selectedThreadID = "thread-1"
        appState.selectedPreset = "terminal"

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" {
                return NSNull()
            }
            throw TestError.forcedFailure
        }
        multiplexer.attachHandler = { _, _ in
            throw JSONRPCErrorResponse(
                code: -32041,
                message: "attach failed",
                data: ["kind": "terminal.session_missing"]
            )
        }

        await appState.attachSelectedPreset()
        await appState.attachSelectedPreset()

        XCTAssertEqual(multiplexer.attachCallCount, 1)
        XCTAssertEqual(connection.requests.filter { $0.method == "preset.start" }.count, 1)
    }

    func testThreadProgressFailureCancelsPendingAttach() async {
        let (connection, _, _, multiplexer, appState) = makeConfiguredAppStateWithDoubles()
        appState.projects = [makeProject(id: "project-1")]
        appState.threads = [makeThread(id: "thread-1", status: .active)]
        appState.selectedThreadID = "thread-1"
        appState.selectedPreset = "terminal"

        connection.requestHandler = { method, _, _ in
            if method == "preset.start" {
                return NSNull()
            }
            throw TestError.forcedFailure
        }

        var attachCancelled = false
        multiplexer.attachHandler = { _, _ in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch is CancellationError {
                attachCancelled = true
                throw CancellationError()
            }
            throw TestError.forcedFailure
        }

        appState.scheduleAttachSelectedPreset()
        try? await Task.sleep(nanoseconds: 20_000_000)

        appState.handleDaemonEvent(
            method: "thread.progress",
            params: [
                "thread_id": "thread-1",
                "step": "running_hooks",
                "message": "Thread creation failed",
                "error": "git fetch origin failed",
            ]
        )

        let cancelled = await waitForCondition { attachCancelled }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(appState.threads.first?.status, .failed)
    }

    func testThreadProgressFailureUpdatesStatusToFailed() {
        let (_, database, _, _, appState) = makeConfiguredAppStateWithDoubles()
        appState.threads = [
            ThreadModel(
                id: "thread-1",
                projectId: "project-1",
                name: "Demo",
                branch: "main",
                worktreePath: "/tmp/demo",
                status: .creating,
                sourceType: "branch",
                createdAt: Date(),
                tmuxSession: ""
            )
        ]

        appState.handleDaemonEvent(
            method: "thread.progress",
            params: [
                "thread_id": "thread-1",
                "step": "creating_worktree",
                "message": "failed",
                "error": "boom",
            ]
        )

        XCTAssertEqual(appState.threads.first?.status, .failed)
        XCTAssertEqual(database.updatedStatuses.last?.threadID, "thread-1")
        XCTAssertEqual(database.updatedStatuses.last?.status, .failed)
    }

    func testAttachNotAttemptedForFailedThread() async {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            if method == "terminal.attach" {
                return ["channel_id": 17]
            }
            return NSNull()
        }
        let database = MockDatabaseManager()
        let syncService = MockSyncService()
        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        defer { multiplexer.detachAll() }

        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer
        )
        appState.projects = [makeProject(id: "project-1")]

        let preset = Preset.defaults.first?.name ?? "terminal"
        appState.threads = [
            ThreadModel(
                id: "thread-1",
                projectId: "project-1",
                name: "Failed thread",
                branch: "main",
                worktreePath: "/tmp/demo",
                status: .failed,
                sourceType: "branch",
                createdAt: Date(),
                tmuxSession: ""
            )
        ]
        appState.selectedPreset = preset
        appState.selectedThreadID = "thread-1"

        await appState.attachSelectedPreset()

        XCTAssertEqual(connection.requests.filter { $0.method == "terminal.attach" }.count, 0)
        XCTAssertNil(appState.selectedEndpoint)
    }

    private func makeConfiguredAppState() -> AppState {
        makeConfiguredAppStateWithDoubles().4
    }

    private func makeConfiguredAppStateWithDoubles() -> (MockDaemonConnection, MockDatabaseManager, MockSyncService, MockTerminalMultiplexer, AppState) {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let appState = AppState()
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.projects = [makeProject(id: "project-1")]
        return (connection, database, sync, multiplexer, appState)
    }

    private func makeThread(id: String, status: ThreadStatus) -> ThreadModel {
        ThreadModel(
            id: id,
            projectId: "project-1",
            name: "Demo",
            branch: "main",
            worktreePath: "/tmp/demo",
            status: status,
            sourceType: "branch",
            createdAt: Date(),
            tmuxSession: ""
        )
    }

    private func makeProject(id: String) -> Project {
        Project(
            id: id,
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
    }
}
