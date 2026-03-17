import XCTest
@testable import Threadmill

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testLoadConversationsSelectsFirstConversationAndLoadsMessages() async throws {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let conversation = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "First", time: 1)
        let message = OCMessage(id: "msg_1", sessionID: "ses_1", role: "assistant")

        conversations.activeConversationsResult = .success([conversation])
        mock.getMessagesResult = .success([message])

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")

        XCTAssertEqual(viewModel.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(viewModel.currentConversation?.id, conversation.id)
        XCTAssertEqual(viewModel.messages.map(\.id), [message.id])
        XCTAssertEqual(conversations.activeThreadIDs, ["thread_1"])
        XCTAssertEqual(mock.fetchedMessages.first?.sessionID, "ses_1")
    }

    func testLoadConversationsWithNoSessionsKeepsConversationListEmpty() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()

        conversations.activeConversationsResult = .success([])

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")

        XCTAssertTrue(conversations.createdConversations.isEmpty)
        XCTAssertNil(viewModel.currentConversation)
        XCTAssertTrue(viewModel.conversations.isEmpty)
    }

    func testArchiveConversationLeavesEmptyStateWhenLastConversationIsClosed() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let onlyConversation = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "", time: 1)

        conversations.activeConversationsResult = .success([onlyConversation])
        mock.getMessagesResult = .success([])

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")
        await viewModel.archiveConversation(onlyConversation)

        XCTAssertEqual(conversations.archivedConversationIDs, ["conv_1"])
        XCTAssertTrue(conversations.createdConversations.isEmpty)
        XCTAssertNil(viewModel.currentConversation)
        XCTAssertTrue(viewModel.conversations.isEmpty)
    }

    func testCreateConversationInitializesSessionWithoutModelSelectionState() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let created = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "", time: 1)

        conversations.createConversationResult = .success(created)
        mock.getMessagesResult = .success([])

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)

        await viewModel.createConversation(threadID: "thread_1", directory: "/tmp/worktree", harness: .openCodeServe)

        XCTAssertEqual(conversations.createdConversations.first?.threadID, "thread_1")
        XCTAssertEqual(conversations.createdConversations.first?.directory, "/tmp/worktree")
        XCTAssertEqual(conversations.createdConversations.first?.harness, .openCodeServe)
    }

    func testLoadConversationsExcludesArchivedConversations() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let active = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "Active", time: 2)

        // activeConversations returns only non-archived; loadConversations must use it
        conversations.activeConversationsResult = .success([active])
        mock.getMessagesResult = .success([])

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")

        XCTAssertEqual(viewModel.conversations.map(\.id), ["conv_1"])
        XCTAssertTrue(conversations.activeThreadIDs.contains("thread_1"))
        // listConversations must NOT be called — it returns archived conversations too
        XCTAssertTrue(conversations.listedThreadIDs.isEmpty)
    }

    func testChatViewModelSourceDoesNotReferenceProviderModelPickerState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Chat/ChatViewModel.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("getProviders("))
        XCTAssertFalse(source.contains("availableModels"))
        XCTAssertFalse(source.contains("setPreferredModel"))
    }

    func testCreateConversationStartsEventStreamWhenLoadedDirectly() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let created = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: nil, title: "", time: 1)

        conversations.createConversationResult = .success(created)

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.createConversation(threadID: "thread_1", directory: "/tmp/worktree", harness: .openCodeServe)

        XCTAssertEqual(mock.streamedDirectories, ["/tmp/worktree"])
    }

    func testSendPromptStreamsAssistantTextAndStopsWhenSessionBecomesIdle() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let conversation = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "", time: 1)

        conversations.activeConversationsResult = .success([conversation])
        mock.getMessagesResult = .success([])

        var continuation: AsyncStream<OCEvent>.Continuation?
        mock.eventStream = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")
        await viewModel.sendPrompt(text: "hello")

        XCTAssertTrue(viewModel.isGenerating)
        XCTAssertEqual(mock.promptedSessions.first?.prompt, "hello")
        XCTAssertEqual(mock.promptedSessions.first?.sessionID, "ses_1")

        continuation?.yield(.messageUpdated(OCMessage(id: "msg_assistant", sessionID: "ses_1", role: "assistant")))
        continuation?.yield(.messagePartUpdated(OCMessagePartUpdate(
            part: OCMessagePart(id: "part_1", type: "text", sessionID: "ses_1", messageID: "msg_assistant", text: nil),
            delta: "Hel"
        )))
        continuation?.yield(.messagePartUpdated(OCMessagePartUpdate(
            part: OCMessagePart(id: "part_1", type: "text", sessionID: "ses_1", messageID: "msg_assistant", text: nil),
            delta: "lo"
        )))
        continuation?.yield(.sessionStatus(OCSessionStatusEvent(sessionID: "ses_1", status: OCSessionStatus(type: "idle", attempt: nil, message: nil, next: nil))))

        let becameIdle = await waitForCondition {
            !viewModel.isGenerating
        }
        XCTAssertTrue(becameIdle)

        let assistantMessage = viewModel.messages.first(where: { $0.id == "msg_assistant" })
        let text = assistantMessage?.parts.first(where: { $0.id == "part_1" })?.text
        XCTAssertEqual(text, "Hello")
    }

    func testSendPromptResetsGenerationWhenEventStreamEndsWithoutIdleStatus() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let conversation = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "", time: 1)

        conversations.activeConversationsResult = .success([conversation])
        mock.getMessagesResult = .success([])

        var continuation: AsyncStream<OCEvent>.Continuation?
        mock.eventStream = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")
        await viewModel.sendPrompt(text: "hello")

        XCTAssertTrue(viewModel.isGenerating)

        continuation?.finish()

        let resetAfterStreamEnd = await waitForCondition {
            !viewModel.isGenerating
        }
        XCTAssertTrue(resetAfterStreamEnd)
    }

    func testSelectConversationIgnoresStaleMessageLoadResults() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let firstConversation = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "First", time: 1)
        let secondConversation = makeConversation(id: "conv_2", threadID: "thread_1", sessionID: "ses_2", title: "Second", time: 2)

        conversations.activeConversationsResult = .success([firstConversation, secondConversation])
        mock.getMessagesHandler = { sessionID, _ in
            if sessionID == "ses_1" {
                try await Task.sleep(nanoseconds: 150_000_000)
                return [OCMessage(id: "msg_stale", sessionID: sessionID, role: "assistant")]
            }
            return [OCMessage(id: "msg_fresh", sessionID: sessionID, role: "assistant")]
        }

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        let loadTask = Task {
            await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")
        }

        let selectedSecond = await waitForCondition {
            !viewModel.conversations.isEmpty
        }
        XCTAssertTrue(selectedSecond)

        await viewModel.selectConversation(secondConversation)
        _ = await loadTask.value

        XCTAssertEqual(viewModel.currentConversation?.id, secondConversation.id)
        XCTAssertEqual(viewModel.messages.map(\.id), ["msg_fresh"])
    }

    func testLoadConversationsRestartsEventStreamAfterStreamCompletes() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        conversations.activeConversationsResult = .success([])
        conversations.createConversationResult = .failure(TestError.forcedFailure)
        mock.eventStream = AsyncStream { continuation in
            continuation.finish()
        }

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")
        let streamFinished = await waitForCondition {
            mock.streamedDirectories.count == 1
        }
        XCTAssertTrue(streamFinished)

        for _ in 0..<5 {
            await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")
            if mock.streamedDirectories.count == 2 {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(mock.streamedDirectories.count, 2)
    }

    func testAbortCallsClientForCurrentConversation() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let conversation = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "First", time: 1)

        conversations.activeConversationsResult = .success([conversation])
        mock.getMessagesResult = .success([])

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")
        await viewModel.abort()

        XCTAssertEqual(mock.abortedSessions.first?.sessionID, "ses_1")
        XCTAssertEqual(mock.abortedSessions.first?.directory, "/tmp/worktree")
    }

    func testSessionUpdatedAutoTitlesUntitledConversation() async {
        let mock = MockOpenCodeClient()
        let conversations = MockChatConversationService()
        let untitledConversation = makeConversation(id: "conv_1", threadID: "thread_1", sessionID: "ses_1", title: "", time: 1)

        conversations.activeConversationsResult = .success([untitledConversation])
        mock.getMessagesResult = .success([])

        var continuation: AsyncStream<OCEvent>.Continuation?
        mock.eventStream = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }

        let viewModel = ChatViewModel(chatHarnessRegistry: .openCode(client: mock), chatConversationService: conversations)
        await viewModel.loadConversations(threadID: "thread_1", directory: "/tmp/worktree")

        continuation?.yield(.sessionUpdated(OCSession(
            id: "ses_1",
            slug: nil,
            title: "Generated title",
            directory: "/tmp/worktree",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )))

        let updated = await waitForCondition {
            viewModel.currentConversation?.title == "Generated title"
        }

        XCTAssertTrue(updated)
        XCTAssertEqual(conversations.updatedTitles.first?.id, "conv_1")
        XCTAssertEqual(conversations.updatedTitles.first?.title, "Generated title")
    }

    private func makeConversation(id: String, threadID: String, sessionID: String?, title: String, time: TimeInterval) -> ChatConversation {
        var conversation = ChatConversation(threadID: threadID, title: title)
        let timestamp = Date(timeIntervalSince1970: time)
        conversation.id = id
        conversation.sessionID = sessionID
        conversation.createdAt = timestamp
        conversation.updatedAt = timestamp
        conversation.isArchived = false
        return conversation
    }
}
