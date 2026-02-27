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
        mock.initSessionResult = .success(session)
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
