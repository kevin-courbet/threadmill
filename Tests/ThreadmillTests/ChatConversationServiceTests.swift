import XCTest
@testable import Threadmill

@MainActor
final class ChatConversationServiceTests: XCTestCase {
    func testCreateConversationInitializesCreatedSession() async throws {
        let databaseManager = MockDatabaseManager()
        let openCodeClient = MockOpenCodeClient()
        let createdSession = OCSession(
            id: "ses_1",
            slug: nil,
            title: "",
            directory: "/tmp/worktree",
            projectID: "proj_1",
            version: nil,
            parentID: nil,
            time: nil,
            summary: nil
        )

        openCodeClient.createSessionResult = .success(createdSession)
        openCodeClient.initSessionResult = .success(createdSession)

        let service = ChatConversationService(databaseManager: databaseManager, openCodeClient: openCodeClient)
        let conversation = try await service.createConversation(threadID: "thread_1", directory: "/tmp/worktree")

        XCTAssertEqual(openCodeClient.createdSessionsInDirectories, ["/tmp/worktree"])
        XCTAssertEqual(openCodeClient.createdSessions.first, "/tmp/worktree")
        XCTAssertEqual(openCodeClient.initializedSessions.count, 1)
        XCTAssertEqual(openCodeClient.initializedSessions.first?.id, "ses_1")
        XCTAssertEqual(conversation.opencodeSessionID, "ses_1")
    }

    func testCreateConversationDoesNotPersistWhenSessionCreationFails() async {
        let databaseManager = MockDatabaseManager()
        let openCodeClient = MockOpenCodeClient()
        openCodeClient.createSessionResult = .failure(TestError.forcedFailure)

        let service = ChatConversationService(databaseManager: databaseManager, openCodeClient: openCodeClient)

        do {
            _ = try await service.createConversation(threadID: "thread_1", directory: "/tmp/worktree")
            XCTFail("Expected createConversation to throw")
        } catch {
            XCTAssertEqual(databaseManager.conversations.count, 0)
            XCTAssertEqual(openCodeClient.initializedSessions.count, 0)
        }
    }
}
