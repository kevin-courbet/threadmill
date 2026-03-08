import XCTest
@testable import Threadmill

@MainActor
final class ChatConversationServiceTests: XCTestCase {
    func testCreateConversationLinksSessionAndSavesImmediatelyThenInitsInBackground() async throws {
        let openCode = MockOpenCodeClient()
        let database = MockDatabaseManager()

        let createdSession = OCSession(
            id: "ses_new",
            slug: nil,
            title: "",
            directory: "/home/wsl/dev/project",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )
        let initializedSession = OCSession(
            id: "ses_new",
            slug: nil,
            title: "",
            directory: "/home/wsl/dev/project",
            projectID: "proj_1",
            version: "1",
            parentID: nil,
            time: nil,
            summary: nil
        )

        openCode.createSessionResult = .success(createdSession)
        openCode.initSessionResult = .success(initializedSession)

        let service = ChatConversationService(
            databaseManager: database,
            openCodeClient: openCode
        )

        let conversation = try await service.createConversation(
            threadID: "thread_1",
            directory: "/home/wsl/dev/project"
        )

        // createSession called with correct directory
        XCTAssertEqual(openCode.createdSessionsInDirectories, ["/home/wsl/dev/project"])

        // Conversation saved immediately with linked session (before init completes)
        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(database.conversations.first?.id, conversation.id)
        XCTAssertEqual(database.conversations.first?.opencodeSessionID, "ses_new")
        XCTAssertEqual(database.conversations.first?.threadID, "thread_1")

        // initSession fires in background — wait for it to complete
        let initCalled = await waitForCondition { openCode.initializedSessions.count == 1 }
        XCTAssertTrue(initCalled)
        XCTAssertEqual(openCode.initializedSessions.first?.id, "ses_new")
        XCTAssertEqual(openCode.initializedSessions.first?.directory, "/home/wsl/dev/project")
    }

    func testCreateConversationPropagatesCreateSessionError() async {
        let openCode = MockOpenCodeClient()
        let database = MockDatabaseManager()

        openCode.createSessionResult = .failure(OpenCodeClientError.unexpectedStatusCode(503))

        let service = ChatConversationService(
            databaseManager: database,
            openCodeClient: openCode
        )

        do {
            _ = try await service.createConversation(
                threadID: "thread_1",
                directory: "/home/wsl/dev/project"
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is OpenCodeClientError)
        }

        // Nothing should be saved to database
        XCTAssertTrue(database.conversations.isEmpty)
        // initSession should not have been called
        XCTAssertTrue(openCode.initializedSessions.isEmpty)
    }

    func testCreateConversationSavesEvenWhenInitSessionFailsInBackground() async throws {
        let openCode = MockOpenCodeClient()
        let database = MockDatabaseManager()

        let createdSession = OCSession(
            id: "ses_new",
            slug: nil,
            title: "",
            directory: "/home/wsl/dev/project",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )
        openCode.createSessionResult = .success(createdSession)
        openCode.initSessionResult = .failure(OpenCodeClientError.unexpectedStatusCode(500))

        let service = ChatConversationService(
            databaseManager: database,
            openCodeClient: openCode
        )

        // createConversation succeeds — initSession failure is background-only
        let conversation = try await service.createConversation(
            threadID: "thread_1",
            directory: "/home/wsl/dev/project"
        )

        // Conversation saved with session linked
        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(database.conversations.first?.opencodeSessionID, "ses_new")
        XCTAssertEqual(conversation.threadID, "thread_1")

        // Background init was attempted (and failed silently)
        let initCalled = await waitForCondition { openCode.initializedSessions.count == 1 }
        XCTAssertTrue(initCalled)
    }
}
