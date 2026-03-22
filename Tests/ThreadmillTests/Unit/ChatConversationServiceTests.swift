import XCTest
@testable import Threadmill

@MainActor
final class ChatConversationServiceTests: XCTestCase {
    func testCreateConversationSavesConversationWithSelectedAgentTypeWithoutOpenCodeBootstrap() async throws {
        let openCode = MockOpenCodeClient()
        let database = MockDatabaseManager()

        let service = ChatConversationService(
            databaseManager: database,
            openCodeClient: openCode
        )

        let conversation = try await service.createConversation(
            threadID: "thread_1",
            directory: "/home/wsl/dev/project",
            agentType: "claude"
        )

        XCTAssertTrue(openCode.createdSessionsInDirectories.isEmpty)
        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(database.conversations.first?.id, conversation.id)
        XCTAssertNil(database.conversations.first?.agentSessionID)
        XCTAssertEqual(database.conversations.first?.agentType, "claude")
        XCTAssertEqual(database.conversations.first?.threadID, "thread_1")
        XCTAssertTrue(openCode.initializedSessions.isEmpty)
    }

    func testCreateConversationDefaultsAgentTypeToOpenCode() async throws {
        let openCode = MockOpenCodeClient()
        let database = MockDatabaseManager()

        let service = ChatConversationService(
            databaseManager: database,
            openCodeClient: openCode
        )

        let conversation = try await service.createConversation(
            threadID: "thread_1",
            directory: "/home/wsl/dev/project",
            agentType: "opencode"
        )

        XCTAssertEqual(conversation.agentType, "opencode")
        XCTAssertNil(conversation.agentSessionID)
    }
}
