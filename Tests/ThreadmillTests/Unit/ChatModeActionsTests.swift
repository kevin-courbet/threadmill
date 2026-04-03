import SwiftUI
import XCTest
@testable import Threadmill

@MainActor
final class ChatModeActionsTests: XCTestCase {
    func testCreateChatConversationSelectsNewConversationAndDoesNotOverrideHarnessModel() async {
        let appState = AppState()
        let database = MockDatabaseManager()
        let connection = MockDaemonConnection()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let chatConversationService = MockChatConversationService()

        let pool = makeSingleRemoteConnectionPool(connection: connection)
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer,
            chatConversationService: chatConversationService
        )

        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature/chat",
            branch: "feature/chat",
            worktreePath: "/tmp/worktree",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_thread-1",
            portOffset: nil
        )
        appState.threads = [thread]
        appState.selectedThreadID = thread.id
        appState.projects = [
            Project(
                id: "project-1",
                name: "project",
                remotePath: "/tmp/project",
                defaultBranch: "main",
                presets: [],
                agents: [AgentConfig(name: "claude", command: "claude", cwd: nil)],
                remoteId: nil,
                repoId: nil
            )
        ]

        var createdConversation = ChatConversation(threadID: thread.id)
        createdConversation.id = "conversation-1"
        chatConversationService.createConversationResult = .success(createdConversation)

        var selectedConversationID: String?
        var reloadToken = 0
        let tabStateManager = ThreadTabStateManager()

        ChatModeActions.createChatConversation(
            thread: thread,
            appState: appState,
            selectedChatConversationIDBinding: Binding(
                get: { selectedConversationID },
                set: { selectedConversationID = $0 }
            ),
            chatReloadToken: Binding(
                get: { reloadToken },
                set: { reloadToken = $0 }
            ),
            tabStateManager: tabStateManager,
            harness: .opencode
        )

        let didSelectConversation = await waitForCondition {
            selectedConversationID == "conversation-1" && reloadToken == 1
        }

        XCTAssertTrue(didSelectConversation)
        XCTAssertEqual(chatConversationService.createdConversations.first?.threadID, "thread-1")
        XCTAssertEqual(chatConversationService.createdConversations.first?.agentType, "opencode")
    }

    func testCreateChatConversationSurfacesErrorAndLeavesSelectionUnchanged() async {
        let appState = AppState()
        let database = MockDatabaseManager()
        let connection = MockDaemonConnection()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let chatConversationService = MockChatConversationService()

        let pool = makeSingleRemoteConnectionPool(connection: connection)
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer,
            chatConversationService: chatConversationService
        )

        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature/chat",
            branch: "feature/chat",
            worktreePath: "/tmp/worktree",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_thread-1",
            portOffset: nil
        )
        appState.threads = [thread]
        appState.selectedThreadID = thread.id
        chatConversationService.createConversationResult = .failure(TestError.forcedFailure)

        var selectedConversationID: String? = "conversation-existing"
        var reloadToken = 4
        var errorMessage: String?
        let tabStateManager = ThreadTabStateManager()

        ChatModeActions.createChatConversation(
            thread: thread,
            appState: appState,
            selectedChatConversationIDBinding: Binding(
                get: { selectedConversationID },
                set: { selectedConversationID = $0 }
            ),
            chatReloadToken: Binding(
                get: { reloadToken },
                set: { reloadToken = $0 }
            ),
            tabStateManager: tabStateManager,
            errorMessageBinding: Binding(
                get: { errorMessage },
                set: { errorMessage = $0 }
            ),
            harness: .opencode
        )

        let didSurfaceError = await waitForCondition {
            errorMessage != nil
        }

        XCTAssertTrue(didSurfaceError)
        XCTAssertEqual(selectedConversationID, "conversation-existing")
        XCTAssertEqual(reloadToken, 4)
    }

    func testCreateChatConversationSelectsConversationBeforeSessionStartCompletes() async {
        let appState = AppState()
        let database = MockDatabaseManager()
        let connection = MockDaemonConnection()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let chatConversationService = MockChatConversationService()
        let agentSessionManager = AgentSessionManager(connectionManager: connection)

        let pool = makeSingleRemoteConnectionPool(connection: connection)
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer,
            chatConversationService: chatConversationService,
            agentSessionManager: agentSessionManager
        )

        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature/chat",
            branch: "feature/chat",
            worktreePath: "/tmp/worktree",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_thread-1",
            portOffset: nil
        )
        appState.threads = [thread]
        appState.selectedThreadID = thread.id

        var createdConversation = ChatConversation(threadID: thread.id)
        createdConversation.id = "conversation-3"
        chatConversationService.createConversationResult = .success(createdConversation)

        connection.requestHandler = { method, _, _ in
            if method == "chat.start" {
                throw TestError.forcedFailure
            }
            throw TestError.missingStub
        }

        var selectedConversationID: String?
        var reloadToken = 0
        var errorMessage: String?
        let tabStateManager = ThreadTabStateManager()

        ChatModeActions.createChatConversation(
            thread: thread,
            appState: appState,
            selectedChatConversationIDBinding: Binding(
                get: { selectedConversationID },
                set: { selectedConversationID = $0 }
            ),
            chatReloadToken: Binding(
                get: { reloadToken },
                set: { reloadToken = $0 }
            ),
            tabStateManager: tabStateManager,
            errorMessageBinding: Binding(
                get: { errorMessage },
                set: { errorMessage = $0 }
            ),
            harness: .opencode
        )

        let didSelectConversation = await waitForCondition {
            selectedConversationID == "conversation-3" && reloadToken == 1
        }

        XCTAssertTrue(didSelectConversation)

        let didSurfaceSessionStartError = await waitForCondition {
            errorMessage != nil
        }
        XCTAssertTrue(didSurfaceSessionStartError)
    }

    func testArchiveChatConversationsSurfacesErrorAndSkipsReloadOnFailure() async {
        let appState = AppState()
        let database = MockDatabaseManager()
        let connection = MockDaemonConnection()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let chatConversationService = MockChatConversationService()

        let pool = makeSingleRemoteConnectionPool(connection: connection)
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer,
            chatConversationService: chatConversationService
        )

        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature/chat",
            branch: "feature/chat",
            worktreePath: "/tmp/worktree",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_thread-1",
            portOffset: nil
        )
        appState.threads = [thread]
        appState.selectedThreadID = thread.id
        chatConversationService.archiveConversationResult = .failure(TestError.forcedFailure)

        var selectedConversationID: String? = "conversation-1"
        var reloadToken = 2
        var errorMessage: String?
        let tabStateManager = ThreadTabStateManager()

        let makeConversation: (String) -> ChatConversation = { id in
            var conversation = ChatConversation(threadID: thread.id)
            conversation.id = id
            return conversation
        }
        let existingConversations = [makeConversation("conversation-1"), makeConversation("conversation-2")]

        ChatModeActions.archiveChatConversations(
            ["conversation-1"],
            appState: appState,
            chatConversations: { existingConversations },
            selectedChatConversationIDBinding: Binding(
                get: { selectedConversationID },
                set: { selectedConversationID = $0 }
            ),
            chatReloadToken: Binding(
                get: { reloadToken },
                set: { reloadToken = $0 }
            ),
            tabStateManager: tabStateManager,
            errorMessageBinding: Binding(
                get: { errorMessage },
                set: { errorMessage = $0 }
            )
        )

        let didSurfaceError = await waitForCondition {
            errorMessage != nil
        }

        XCTAssertTrue(didSurfaceError)
        XCTAssertEqual(selectedConversationID, "conversation-1")
        XCTAssertEqual(reloadToken, 2)
    }

    func testCreateChatConversationUsesThreadContextWhenSelectionChanges() async {
        let appState = AppState()
        let database = MockDatabaseManager()
        let connection = MockDaemonConnection()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let chatConversationService = MockChatConversationService()

        let pool = makeSingleRemoteConnectionPool(connection: connection)
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer,
            chatConversationService: chatConversationService
        )

        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature/chat",
            branch: "feature/chat",
            worktreePath: "/tmp/worktree",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_thread-1",
            portOffset: nil
        )
        appState.threads = [thread]
        appState.selectedThreadID = nil

        var createdConversation = ChatConversation(threadID: thread.id)
        createdConversation.id = "conversation-2"
        chatConversationService.createConversationResult = .success(createdConversation)

        var selectedConversationID: String?
        var reloadToken = 0
        let tabStateManager = ThreadTabStateManager()

        ChatModeActions.createChatConversation(
            thread: thread,
            appState: appState,
            selectedChatConversationIDBinding: Binding(
                get: { selectedConversationID },
                set: { selectedConversationID = $0 }
            ),
            chatReloadToken: Binding(
                get: { reloadToken },
                set: { reloadToken = $0 }
            ),
            tabStateManager: tabStateManager,
            harness: .opencode
        )

        let didSelectConversation = await waitForCondition {
            selectedConversationID == "conversation-2" && reloadToken == 1
        }

        XCTAssertTrue(didSelectConversation)
        XCTAssertEqual(chatConversationService.createdConversations.first?.threadID, "thread-1")
    }

    func testStateUpdateDoesNotReSelectArchivedConversation() {
        let appState = AppState()
        let database = MockDatabaseManager()
        let connection = MockDaemonConnection()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let chatConversationService = MockChatConversationService()

        let pool = makeSingleRemoteConnectionPool(connection: connection)
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer,
            chatConversationService: chatConversationService
        )

        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature/chat",
            branch: "feature/chat",
            worktreePath: "/tmp/worktree",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_thread-1",
            portOffset: nil
        )
        appState.threads = [thread]
        appState.selectedThreadID = thread.id

        let makeConversation: (String) -> ChatConversation = { id in
            var c = ChatConversation(threadID: thread.id)
            c.id = id
            return c
        }

        // Simulate: conversation-1 was archived, conversation-2 survives.
        // The VM still holds conversation-1 as currentConversation (stale).
        let survivingConversations = [makeConversation("conversation-2")]
        let staleCurrentConversation = makeConversation("conversation-1")

        var selectedConversationID: String? = "conversation-2"
        var chatConversations: [ChatConversation] = []
        let tabStateManager = ThreadTabStateManager()

        ChatModeActions.handleChatConversationStateUpdate(
            survivingConversations,
            staleCurrentConversation,
            appState: appState,
            selectedChatConversationIDBinding: Binding(
                get: { selectedConversationID },
                set: { selectedConversationID = $0 }
            ),
            chatConversations: Binding(
                get: { chatConversations },
                set: { chatConversations = $0 }
            ),
            tabStateManager: tabStateManager
        )

        // Must NOT re-select the archived conversation-1
        XCTAssertEqual(selectedConversationID, "conversation-2")
        XCTAssertEqual(chatConversations.count, 1)
        XCTAssertEqual(chatConversations.first?.id, "conversation-2")
    }

    func testRefreshChatConversationsNormalizesChronologicalTabOrder() async {
        let appState = AppState()
        let database = MockDatabaseManager()
        let connection = MockDaemonConnection()
        let syncService = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()
        let chatConversationService = MockChatConversationService()

        let pool = makeSingleRemoteConnectionPool(connection: connection)
        appState.configure(
            connectionPool: pool,
            databaseManager: database,
            syncService: syncService,
            multiplexer: multiplexer,
            chatConversationService: chatConversationService
        )

        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature/chat",
            branch: "feature/chat",
            worktreePath: "/tmp/worktree",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(),
            tmuxSession: "tm_thread-1",
            portOffset: nil
        )
        appState.threads = [thread]
        appState.selectedThreadID = thread.id

        let older = ChatConversation(
            id: "conversation-1",
            threadID: thread.id,
            agentSessionID: "ses-1",
            title: "",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            isArchived: false
        )
        let newer = ChatConversation(
            id: "conversation-2",
            threadID: thread.id,
            agentSessionID: "ses-2",
            title: "",
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2),
            isArchived: false
        )
        chatConversationService.activeConversationsResult = .success([newer, older])

        var chatConversations: [ChatConversation] = []
        var selectedConversationID: String?
        let tabStateManager = ThreadTabStateManager()

        await ChatModeActions.refreshChatConversations(
            for: thread,
            appState: appState,
            chatConversations: Binding(get: { chatConversations }, set: { chatConversations = $0 }),
            selectedChatConversationIDBinding: Binding(get: { selectedConversationID }, set: { selectedConversationID = $0 }),
            tabStateManager: tabStateManager
        )

        XCTAssertEqual(chatConversations.map(\.id), ["conversation-1", "conversation-2"])
        XCTAssertEqual(selectedConversationID, "conversation-1")
    }
}
