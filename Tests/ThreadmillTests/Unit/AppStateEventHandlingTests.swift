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
        let (_, _, syncService, _, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(method: "thread.created", params: ["thread_id": "thread-2"])

        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testHandleDaemonEventThreadRemovedTriggersSync() async {
        let (_, _, syncService, _, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(method: "thread.removed", params: ["thread_id": "thread-2"])

        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testHandleDaemonEventUnknownEventDoesNotCrash() async {
        let (_, _, syncService, _, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(method: "thread.unknown", params: ["foo": "bar"])
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(syncService.syncCount, 0)
    }

    func testHandleDaemonEventChatStatusChangedUpdatesAgentStatus() {
        let (_, _, _, _, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(
            method: "chat.status_changed",
            params: [
                "thread_id": "thread-1",
                "agent_status": [
                    "status": "stalled",
                    "worker_count": 3,
                ],
            ]
        )

        XCTAssertEqual(appState.agentStatus["thread-1"]?.status, .stalled(workerCount: 3))
        XCTAssertEqual(appState.agentStatus["thread-1"]?.workerCount, 3)
    }

    func testHandleDaemonEventChatSessionEndedClearsThreadStatus() async {
        let (_, _, syncService, _, _, appState) = makeConfiguredAppStateWithDoubles()
        appState.agentStatus["thread-1"] = AgentActivityInfo.from(rawStatus: "busy", workerCount: 2)

        appState.handleDaemonEvent(
            method: "chat.session_ended",
            params: [
                "thread_id": "thread-1",
                "session_id": "sess-1",
            ]
        )

        XCTAssertNil(appState.agentStatus["thread-1"])
        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testHandleDaemonEventChatSessionReadyStoresCapabilities() async {
        let (_, _, syncService, _, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(
            method: "chat.session_ready",
            params: [
                "thread_id": "thread-1",
                "session_id": "sess-1",
                "capabilities": [
                    "modes": [
                        "availableModes": [
                            ["id": "chat", "title": "Chat"],
                            ["id": "plan", "title": "Plan"],
                        ],
                        "currentModeId": "plan",
                    ],
                    "models": [
                        "availableModels": [
                            ["id": "gpt-5", "title": "GPT-5"],
                            ["id": "claude-opus-4-6", "title": "Claude Opus 4.6"],
                        ],
                        "currentModelId": "claude-opus-4-6",
                    ],
                ],
            ]
        )

        XCTAssertEqual(appState.chatCapabilitiesByThreadID["thread-1"]?.modes.map(\.id), ["chat", "plan"])
        XCTAssertEqual(appState.chatCapabilitiesByThreadID["thread-1"]?.models.map(\.id), ["gpt-5", "claude-opus-4-6"])
        XCTAssertEqual(appState.chatCapabilitiesByThreadID["thread-1"]?.currentModeID, "plan")
        XCTAssertEqual(appState.chatCapabilitiesByThreadID["thread-1"]?.currentModelID, "claude-opus-4-6")
        if case .ready = appState.chatSessionStateByThreadID["thread-1"] {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected chat session state to become ready")
        }
        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testHandleDaemonEventChatSessionFailedStoresFailedState() {
        let (_, _, _, _, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(
            method: "chat.session_failed",
            params: [
                "thread_id": "thread-1",
                "session_id": "sess-1",
                "error": "session crashed",
            ]
        )

        guard case let .failed(error) = appState.chatSessionStateByThreadID["thread-1"] else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(error.localizedDescription, "session crashed")
    }

    func testHandleDaemonEventChatSessionCreatedTriggersSync() async {
        let (_, _, syncService, _, _, appState) = makeConfiguredAppStateWithDoubles()

        appState.handleDaemonEvent(
            method: "chat.session_created",
            params: [
                "thread_id": "thread-1",
                "session": [
                    "session_id": "sess-1",
                    "agent_type": "opencode",
                    "title": "New chat",
                ],
            ]
        )

        let synced = await waitForCondition { syncService.syncCount == 1 }
        XCTAssertTrue(synced)
    }

    func testDisconnectResetsAgentStatus() {
        let (_, _, _, _, _, appState) = makeConfiguredAppStateWithDoubles()
        appState.agentStatus["thread-1"] = AgentActivityInfo.from(rawStatus: "busy", workerCount: 1)
        appState.chatCapabilitiesByThreadID["thread-1"] = ChatSessionCapabilities(
            modes: [ChatModeCapability(id: "chat")],
            models: [ChatModelCapability(id: "gpt-5")]
        )

        appState.connectionStatus = .disconnected

        XCTAssertTrue(appState.agentStatus.isEmpty)
        XCTAssertTrue(appState.chatCapabilitiesByThreadID.isEmpty)
        XCTAssertTrue(appState.chatSessionStateByThreadID.isEmpty)
    }

    func testHandleDaemonEventCloneProgressDoesNotTriggerSync() async {
        let (_, _, syncService, _, _, appState) = makeConfiguredAppStateWithDoubles()

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

    func testAttachSkipsCreatingAndFailedThreads() async {
        let (connection, _, _, multiplexer, _, appState) = makeConfiguredAppStateWithDoubles()
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
        let (connection, _, _, multiplexer, _, appState) = makeConfiguredAppStateWithDoubles()
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
        multiplexer.attachHandler = { _, _, _ in
            throw JSONRPCErrorResponse(code: -1, message: "tmux session not running: tm_thread_1")
        }

        await appState.attachSelectedPreset()
        await appState.attachSelectedPreset()

        XCTAssertEqual(multiplexer.attachCallCount, 1)
        XCTAssertEqual(connection.requests.filter { $0.method == "preset.start" }.count, 1)
    }

    func testThreadProgressFailureCancelsPendingAttach() async {
        let (connection, _, _, multiplexer, _, appState) = makeConfiguredAppStateWithDoubles()
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
        multiplexer.attachHandler = { _, _, _ in
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
        let (_, database, _, _, _, appState) = makeConfiguredAppStateWithDoubles()
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

        let appState = AppState(notificationService: MockNotificationService(), isAppActive: { false })
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

    func testChatStatusTransitionBusyToIdleFiresNotification() {
        let (_, _, _, _, notificationService, appState) = makeConfiguredAppStateWithDoubles()
        appState.threads = [makeThread(id: "thread-1", status: .active)]

        appState.handleDaemonEvent(
            method: "chat.status_changed",
            params: [
                "thread_id": "thread-1",
                "agent_status": [
                    "status": "busy",
                    "worker_count": 1,
                ],
            ]
        )

        appState.handleDaemonEvent(
            method: "chat.status_changed",
            params: [
                "thread_id": "thread-1",
                "agent_status": [
                    "status": "idle",
                    "worker_count": 0,
                ],
            ]
        )

        XCTAssertEqual(notificationService.notifications.count, 1)
        XCTAssertEqual(notificationService.notifications.first?.threadName, "Demo")
        XCTAssertEqual(notificationService.notifications.first?.projectName, "demo")
    }

    func testChatStatusTransitionSuppressedWhenViewingSelectedThread() {
        let (_, _, _, _, notificationService, appState) = makeConfiguredAppStateWithDoubles(isAppActive: { true })
        appState.threads = [makeThread(id: "thread-1", status: .active)]
        appState.selectedThreadID = "thread-1"

        appState.handleDaemonEvent(
            method: "chat.status_changed",
            params: [
                "thread_id": "thread-1",
                "agent_status": [
                    "status": "busy",
                    "worker_count": 1,
                ],
            ]
        )

        appState.handleDaemonEvent(
            method: "chat.status_changed",
            params: [
                "thread_id": "thread-1",
                "agent_status": [
                    "status": "idle",
                    "worker_count": 0,
                ],
            ]
        )

        XCTAssertTrue(notificationService.notifications.isEmpty)
    }

    func testChatStatusTransitionSuppressedForStoppedReason() {
        let (_, _, _, _, notificationService, appState) = makeConfiguredAppStateWithDoubles()
        appState.threads = [makeThread(id: "thread-1", status: .active)]

        appState.handleDaemonEvent(
            method: "chat.status_changed",
            params: [
                "thread_id": "thread-1",
                "agent_status": [
                    "status": "busy",
                    "worker_count": 1,
                ],
            ]
        )

        appState.handleDaemonEvent(
            method: "chat.status_changed",
            params: [
                "thread_id": "thread-1",
                "reason": "stopped",
                "agent_status": [
                    "status": "idle",
                    "worker_count": 0,
                ],
            ]
        )

        XCTAssertTrue(notificationService.notifications.isEmpty)
    }

    private func makeConfiguredAppState() -> AppState {
        makeConfiguredAppStateWithDoubles().5
    }

    private func makeConfiguredAppStateWithDoubles(isAppActive: @escaping () -> Bool = { false }) -> (MockDaemonConnection, MockDatabaseManager, MockSyncService, MockTerminalMultiplexer, MockNotificationService, AppState) {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let notificationService = MockNotificationService()
        let appState = AppState(notificationService: notificationService, isAppActive: isAppActive)
        appState.configure(
            connectionPool: makeSingleRemoteConnectionPool(connection: connection),
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.projects = [makeProject(id: "project-1")]
        return (connection, database, sync, multiplexer, notificationService, appState)
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
