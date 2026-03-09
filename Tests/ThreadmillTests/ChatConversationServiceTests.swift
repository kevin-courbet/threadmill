import XCTest
@testable import Threadmill

@MainActor
final class ChatConversationServiceTests: XCTestCase {
    func testCreateConversationLinksSessionAndSavesWithoutCallingInit() async throws {
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

        let service = ChatConversationService(
            databaseManager: database,
            openCodeClient: openCode
        )

        let conversation = try await service.createConversation(
            threadID: "thread_1",
            directory: "/home/wsl/dev/project"
        )

        XCTAssertEqual(openCode.createdSessionsInDirectories, ["/home/wsl/dev/project"])
        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(database.conversations.first?.id, conversation.id)
        XCTAssertEqual(database.conversations.first?.opencodeSessionID, "ses_new")
        XCTAssertEqual(database.conversations.first?.threadID, "thread_1")
        // /init must NOT be called — it sends opencode's default canned prompt
        XCTAssertTrue(openCode.initializedSessions.isEmpty)
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

    func testCreateConversationDoesNotCallInitSession() async throws {
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

        let service = ChatConversationService(
            databaseManager: database,
            openCodeClient: openCode
        )

        let conversation = try await service.createConversation(
            threadID: "thread_1",
            directory: "/home/wsl/dev/project"
        )

        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(conversation.opencodeSessionID, "ses_new")
        XCTAssertTrue(openCode.initializedSessions.isEmpty)
    }
}
