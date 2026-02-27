import XCTest
@testable import Threadmill

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testLoadSessionsSelectsFirstSessionAndLoadsMessages() async throws {
        let mock = MockOpenCodeClient()
        let session = OCSession(
            id: "ses_1",
            slug: "first",
            title: "First",
            directory: "/tmp/worktree",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )
        let message = OCMessage(id: "msg_1", sessionID: session.id, role: "assistant")

        mock.listSessionsResult = .success([session])
        mock.getMessagesResult = .success([message])

        let viewModel = ChatViewModel(openCodeClient: mock)
        await viewModel.loadSessions(directory: "/tmp/worktree")

        XCTAssertEqual(viewModel.sessions.map(\.id), [session.id])
        XCTAssertEqual(viewModel.currentSession?.id, session.id)
        XCTAssertEqual(viewModel.messages.map(\.id), [message.id])
        XCTAssertEqual(mock.listedDirectories, ["/tmp/worktree"])
        XCTAssertEqual(mock.fetchedMessages.first?.sessionID, session.id)
    }

    func testSendPromptStreamsAssistantTextAndStopsWhenSessionBecomesIdle() async {
        let mock = MockOpenCodeClient()
        let session = OCSession(
            id: "ses_1",
            slug: "first",
            title: "First",
            directory: "/tmp/worktree",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )

        mock.listSessionsResult = .success([])
        mock.createSessionResult = .success(session)
        mock.getMessagesResult = .success([])

        var continuation: AsyncStream<OCEvent>.Continuation?
        mock.eventStream = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }

        let viewModel = ChatViewModel(openCodeClient: mock)
        await viewModel.loadSessions(directory: "/tmp/worktree")
        await viewModel.sendPrompt(text: "hello")

        XCTAssertTrue(viewModel.isGenerating)
        XCTAssertEqual(mock.promptedSessions.first?.prompt, "hello")

        continuation?.yield(.messageUpdated(OCMessage(id: "msg_assistant", sessionID: session.id, role: "assistant")))
        continuation?.yield(.messagePartUpdated(OCMessagePartUpdate(
            part: OCMessagePart(id: "part_1", type: "text", sessionID: session.id, messageID: "msg_assistant", text: nil),
            delta: "Hel"
        )))
        continuation?.yield(.messagePartUpdated(OCMessagePartUpdate(
            part: OCMessagePart(id: "part_1", type: "text", sessionID: session.id, messageID: "msg_assistant", text: nil),
            delta: "lo"
        )))
        continuation?.yield(.sessionStatus(OCSessionStatusEvent(sessionID: session.id, status: OCSessionStatus(type: "idle", attempt: nil, message: nil, next: nil))))

        let becameIdle = await waitForCondition {
            !viewModel.isGenerating
        }
        XCTAssertTrue(becameIdle)

        let assistantMessage = viewModel.messages.first(where: { $0.id == "msg_assistant" })
        let text = assistantMessage?.parts.first(where: { $0.id == "part_1" })?.text
        XCTAssertEqual(text, "Hello")
    }

    func testLoadSessionsEnsuresOpenCodeBeforeFirstRequest() async {
        let mock = MockOpenCodeClient()
        mock.listSessionsResult = .success([])

        var ensureCalls = 0
        let viewModel = ChatViewModel(
            openCodeClient: mock,
            ensureOpenCodeRunning: {
                ensureCalls += 1
            }
        )

        await viewModel.loadSessions(directory: "/tmp/worktree")
        await viewModel.loadSessions(directory: "/tmp/worktree")

        XCTAssertEqual(ensureCalls, 1)
        XCTAssertEqual(mock.listedDirectories, ["/tmp/worktree", "/tmp/worktree"])
    }

    func testSelectSessionIgnoresStaleMessageLoadResults() async {
        let mock = MockOpenCodeClient()
        let firstSession = OCSession(
            id: "ses_1",
            slug: "first",
            title: "First",
            directory: "/tmp/worktree",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )
        let secondSession = OCSession(
            id: "ses_2",
            slug: "second",
            title: "Second",
            directory: "/tmp/worktree",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )

        mock.listSessionsResult = .success([firstSession, secondSession])
        mock.getMessagesHandler = { sessionID, _ in
            if sessionID == firstSession.id {
                try await Task.sleep(nanoseconds: 150_000_000)
                return [OCMessage(id: "msg_stale", sessionID: sessionID, role: "assistant")]
            }
            return [OCMessage(id: "msg_fresh", sessionID: sessionID, role: "assistant")]
        }

        let viewModel = ChatViewModel(openCodeClient: mock)
        let loadTask = Task {
            await viewModel.loadSessions(directory: "/tmp/worktree")
        }

        let selectedSecond = await waitForCondition {
            !viewModel.sessions.isEmpty
        }
        XCTAssertTrue(selectedSecond)

        await viewModel.selectSession(id: secondSession.id)
        _ = await loadTask.value

        XCTAssertEqual(viewModel.currentSession?.id, secondSession.id)
        XCTAssertEqual(viewModel.messages.map(\.id), ["msg_fresh"])
    }

    func testLoadSessionsRestartsEventStreamAfterStreamCompletes() async {
        let mock = MockOpenCodeClient()
        mock.listSessionsResult = .success([])
        mock.eventStream = AsyncStream { continuation in
            continuation.finish()
        }

        let viewModel = ChatViewModel(openCodeClient: mock)
        await viewModel.loadSessions(directory: "/tmp/worktree")
        let streamFinished = await waitForCondition {
            mock.streamedDirectories.count == 1
        }
        XCTAssertTrue(streamFinished)

        for _ in 0..<5 {
            await viewModel.loadSessions(directory: "/tmp/worktree")
            if mock.streamedDirectories.count == 2 {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(mock.streamedDirectories.count, 2)
    }

    func testAbortCallsClientForCurrentSession() async {
        let mock = MockOpenCodeClient()
        let session = OCSession(
            id: "ses_1",
            slug: "first",
            title: "First",
            directory: "/tmp/worktree",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )

        mock.listSessionsResult = .success([session])
        mock.getMessagesResult = .success([])

        let viewModel = ChatViewModel(openCodeClient: mock)
        await viewModel.loadSessions(directory: "/tmp/worktree")
        await viewModel.abort()

        XCTAssertEqual(mock.abortedSessions.first?.sessionID, session.id)
        XCTAssertEqual(mock.abortedSessions.first?.directory, "/tmp/worktree")
    }
}
