import XCTest
@testable import Threadmill

@MainActor
final class ChatConversationServiceTests: XCTestCase {
    func testCreateConversationSavesConversationWithSelectedAgentTypeWithoutOpenCodeBootstrap() async throws {
        let database = MockDatabaseManager()

        let service = ChatConversationService(databaseManager: database)

        let conversation = try await service.createConversation(
            threadID: "thread_1",
            
            agentType: "claude"
        )

        XCTAssertEqual(database.conversations.count, 1)
        XCTAssertEqual(database.conversations.first?.id, conversation.id)
        XCTAssertNil(database.conversations.first?.agentSessionID)
        XCTAssertEqual(database.conversations.first?.agentType, "claude")
        XCTAssertEqual(database.conversations.first?.threadID, "thread_1")
    }

    func testCreateConversationDefaultsAgentTypeToOpenCode() async throws {
        let database = MockDatabaseManager()

        let service = ChatConversationService(databaseManager: database)

        let conversation = try await service.createConversation(
            threadID: "thread_1",
            
            agentType: "opencode"
        )

        XCTAssertEqual(conversation.agentType, "opencode")
        XCTAssertNil(conversation.agentSessionID)
    }
}
